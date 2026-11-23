defmodule Rail.Pipeline.Actions.CheckBaseTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.GitHub.Client
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects

  setup %{project: project} do
    task = learnings_task(project, "CKB-1", :review)
    # Git is stubbed, so the worktree is only looked for: a plain directory stands in for it.
    worktree_path = Path.join(System.tmp_dir!(), "rail_ckb_wt_#{System.unique_integer([:positive])}")
    File.mkdir_p!(worktree_path)
    on_exit(fn -> File.rm_rf(worktree_path) end)
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: worktree_path})
    on_exit(fn -> File.rm_rf(task.scratch_path) end)
    %{task: task}
  end

  test "records the branch behind with what conflicts, and tells the pipeline only when that changes", %{
    task: %Task{id: task_id} = task
  } do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline")
    stub(Git, :base_status, fn _path, "main" -> %{behind: true, conflicts: ["lib/a.ex"]} end)

    assert {:ok, %Task{base_behind: true, base_conflicts: ["lib/a.ex"], base_checked_at: %DateTime{}} = checked} =
             Pipeline.check_base(task)

    assert_received {:pipeline_changed, ^task_id}

    assert {:ok, %Task{base_behind: true}} = Pipeline.check_base(checked)
    refute_received {:pipeline_changed, ^task_id}
    assert %Task{base_conflicts: ["lib/a.ex"]} = Repo.reload!(task)
  end

  test "a branch that catches up with the default branch drops GitHub's last refusal, and one still behind keeps it",
       %{task: %Task{id: task_id} = task} do
    {:ok, task} =
      Pipeline.update_task(task, %{
        stage: :finalize,
        marked_ready_at: DateTime.utc_now(),
        base_behind: true,
        merge_error: "Head branch is out of date",
        merge_error_at: DateTime.utc_now()
      })

    stub(Git, :base_status, fn _path, "main" -> %{behind: true, conflicts: []} end)
    assert {:ok, %Task{merge_error: "Head branch is out of date"} = still_behind} = Pipeline.check_base(task)
    assert Task.finalize_state(still_behind) == :refused

    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline")
    stub(Git, :base_status, fn _path, "main" -> %{behind: false, conflicts: []} end)
    assert {:ok, %Task{base_behind: false, merge_error: nil, merge_error_at: nil}} = Pipeline.check_base(still_behind)
    assert_received {:pipeline_changed, ^task_id}
    assert Task.finalize_state(Repo.reload!(task)) == :ready
  end

  test "a refusal on a branch that was never behind is kept", %{task: task} do
    {:ok, task} = Pipeline.update_task(task, %{merge_error: "Required status check is failing", base_behind: false})
    stub(Git, :base_status, fn _path, "main" -> %{behind: false, conflicts: []} end)

    assert {:ok, %Task{merge_error: "Required status check is failing"}} = Pipeline.check_base(task)
  end

  test "a task in its own clone reads as behind once its project's clone has fetched a newer default" do
    remote = create_temp_git_repo(prefix: "rail_ckb_remote")
    clone = Path.join(System.tmp_dir!(), "rail_ckb_clone_#{System.unique_integer([:positive])}")
    git!(remote, ["clone", "--quiet", remote, clone])
    on_exit(fn -> File.rm_rf(clone) end)
    Req.Test.stub(Client, &Req.Test.json(&1, %{"token" => "ghs_token"}))

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Check Base Project",
        github_repo: "org/check-base",
        github_installation_id: 7004,
        key: "CKB",
        default_branch: "main",
        clone_path: clone
      })

    on_exit(fn -> File.rm_rf(Path.join(Rail.tasks_root(), project.id)) end)
    task = learnings_task(project, "CKB-2", :review)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)
    assert {:ok, path} = Git.get_or_create_worktree(project, task)
    # Only the project's clone can bring the task a newer default.
    git!(path, ["remote", "set-url", "origin", "/tmp/nowhere_#{System.unique_integer([:positive])}"])

    assert {:ok, %Task{base_behind: false}} = Pipeline.check_base(task)

    File.write!(Path.join(remote, "later.txt"), "merged later\n")
    git!(remote, ["add", "."])
    git!(remote, ["commit", "-m", "Merged after the task started"])
    git!(clone, ["fetch", "--quiet", "origin"])

    assert {:ok, %Task{base_behind: true, base_conflicts: []}} = Pipeline.check_base(task)
  end

  test "a task with no worktree is left as it is", %{task: task} do
    reject(&Git.base_status/2)

    assert {:ok, %Task{base_checked_at: nil}} = Pipeline.check_base(%{task | worktree_path: "/nonexistent/ckb"})
  end
end
