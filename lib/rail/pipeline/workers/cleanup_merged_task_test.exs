defmodule Rail.Pipeline.Workers.CleanupMergedTaskTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  import Rail.Pipeline.Utils.BuildTask

  alias Rail.Git
  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.DiffComment
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Pipeline.Workers.CleanupMergedTask
  alias Rail.Roles
  alias Rail.Users

  # Git is faked at its boundary: removing a worktree or a branch for real is for `Rail.Git`'s own tests.
  setup %{project: project} do
    stub(Git, :read_default_branch_file, fn _project, path -> {:error, "fatal: path '#{path}' does not exist"} end)
    stub(Git, :remove_worktree, fn _repo_path, _worktree_path -> :ok end)
    stub(Git, :delete_branch, fn _repo_path, _branch -> :ok end)

    Req.Test.stub(Rail.Linear, fn conn ->
      n = System.unique_integer([:positive])

      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_cmt_#{n}", "identifier" => "CMT-#{n}", "title" => "Cleanup Merged #{n}"}
          }
        }
      })
    end)

    {:ok, engineer} = Roles.get_role(project_id: project.id, stage: :engineer)
    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Cleanup Merged"})
    {:ok, task} = Pipeline.create_task(issue, :finalize)
    {:ok, task} = Pipeline.update_task(task, %{stage: :merged, merged_at: DateTime.utc_now()})
    File.mkdir_p!(task.scratch_path)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    %{task: task, engineer: engineer}
  end

  test "a merged task with nothing running loses its worktree, branch, scratch folder and unsent comments", %{
    project: %{clone_path: clone_path},
    task: task
  } do
    worktree_path = Path.join(System.tmp_dir!(), "rail_cmt_wt_#{System.unique_integer([:positive])}")

    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(task, %{worktree_name: "cmt-branch", worktree_path: worktree_path})

    File.write!(Path.join(task.scratch_path, "demo.webm"), "video")

    {:ok, ada} = Users.register_oauth_user(%{github_id: "gh_cmt_ada", login: "cmt-ada", email: "cmt@example.com"})
    diff = %{path: "lib/a.ex", line_kind: :added, line: 1, line_text: "x", filter: :branch, body: "Name it."}
    {:ok, _unsent} = Pipeline.create_diff_comment(user_scope(user: ada), task, diff)
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline")
    expect(Git, :remove_worktree, fn ^clone_path, ^worktree_path -> :ok end)
    expect(Git, :delete_branch, fn ^clone_path, "cmt-branch" -> :ok end)

    assert :ok = perform_job(CleanupMergedTask, %{task_id: task.id})

    assert %Task{cleaned_up_at: %DateTime{}} = Repo.reload!(task)
    assert_received {:pipeline_changed, ^task_id}
    refute File.exists?(task.scratch_path)
    assert [] = Repo.all(from(c in DiffComment, where: c.task_id == ^task_id))
  end

  test "a task with a run running or waiting for resources is tried again later and keeps its files", %{
    task: task,
    engineer: engineer
  } do
    {:ok, run} =
      Pipeline.create_run(%{task_id: task.id, role_id: engineer.id, status: :running, started_at: DateTime.utc_now()})

    for status <- [:running, :waiting_for_resources, :waiting_for_usage] do
      {:ok, _run} = Pipeline.update_run(run, %{status: status})

      assert {:snooze, 30} = perform_job(CleanupMergedTask, %{task_id: task.id})
      assert %Task{cleaned_up_at: nil} = Repo.reload!(task)
      assert File.dir?(task.scratch_path)
    end

    # The run finished since, so the next try cleans it up.
    {:ok, _finished} = Pipeline.update_run(run, %{status: :finished, stage_outcome: :done})
    assert :ok = perform_job(CleanupMergedTask, %{task_id: task.id})
    assert %Task{cleaned_up_at: %DateTime{}} = Repo.reload!(task)
  end

  test "a run stopped on an unanswered question does not hold the cleanup back", %{task: task, engineer: engineer} do
    {:ok, _blocked} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: engineer.id,
        status: :blocked_on_input,
        stage_outcome: :in_progress,
        started_at: DateTime.utc_now()
      })

    assert :ok = perform_job(CleanupMergedTask, %{task_id: task.id})
    assert %Task{cleaned_up_at: %DateTime{}} = Repo.reload!(task)
    refute File.exists?(task.scratch_path)
  end

  describe "a split parent" do
    setup %{project: project} do
      {:ok, parent_issue} = Issues.create_issue(system_scope(), project, %{title: "Split parent"})
      {:ok, parent} = Pipeline.create_task(parent_issue, :split)
      parent = Repo.preload(parent, [:issue, :project])

      children =
        for number <- [1, 2] do
          {:ok, issue} = Issues.create_issue(system_scope(), project, %{title: "Child #{number}", parent: parent_issue})

          {:ok, child} =
            issue.project
            |> build_task(issue, %{stage: :engineer, split_position: number, builds_on: []})
            |> Ecto.Changeset.put_change(:parent_task_id, parent.id)
            |> Repo.insert()

          Repo.preload(child, :issue)
        end

      {:ok, parent} = Pipeline.update_task(parent, %{stage: :merged})
      %{parent: parent, children: children}
    end

    # One child merged and was cleaned up with its merge; the other was canceled and never ran.
    test "takes its remaining children with it, the canceled one included", %{
      parent: parent,
      children: [merged, canceled]
    } do
      {:ok, _merged} = Pipeline.update_task(merged, %{merged_at: DateTime.utc_now(), stage: :merged})
      assert :ok = perform_job(CleanupMergedTask, %{task_id: merged.id})
      assert %Task{cleaned_up_at: %DateTime{} = merged_cleaned_at} = Repo.reload!(merged)
      canceled.issue |> Issue.tracker_changeset(%{state: :canceled}) |> Repo.update!()

      assert :ok = perform_job(CleanupMergedTask, %{task_id: parent.id})

      assert %Task{cleaned_up_at: %DateTime{}} = Repo.reload!(parent)
      assert %Task{cleaned_up_at: %DateTime{}} = Repo.reload!(canceled)
      assert %Task{cleaned_up_at: ^merged_cleaned_at} = Repo.reload!(merged)
    end

    test "is tried again later while one of its children is running", %{
      parent: parent,
      children: [first, second],
      engineer: engineer
    } do
      {:ok, _running} =
        Pipeline.create_run(%{task_id: second.id, role_id: engineer.id, status: :running, started_at: DateTime.utc_now()})

      assert {:snooze, 30} = perform_job(CleanupMergedTask, %{task_id: parent.id})

      for task <- [parent, first, second], do: assert(%Task{cleaned_up_at: nil} = Repo.reload!(task))
    end
  end

  # Clean up clicked while the job waited leaves nothing for it to do.
  test "a task already cleaned up keeps its time and is left alone", %{task: task} do
    {:ok, %Task{cleaned_up_at: %DateTime{} = cleaned_at}} = Pipeline.cleanup_task(task)
    File.mkdir_p!(task.scratch_path)

    assert :ok = perform_job(CleanupMergedTask, %{task_id: task.id})
    assert %Task{cleaned_up_at: ^cleaned_at} = Repo.reload!(task)
    assert File.dir?(task.scratch_path)
  end

  test "a task that is gone needs nothing" do
    assert :ok = perform_job(CleanupMergedTask, %{task_id: "tsk_gone"})
  end
end
