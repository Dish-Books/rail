defmodule Rail.Pipeline.Actions.SendToReviewTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess

  setup %{project: project} do
    scope = system_scope()

    {:ok, backend} = Tools.create_backend(scope, %{name: :claude, executable_path: "/usr/bin/true"})

    {:ok, role} =
      Roles.create_role(scope, project, %{
        backend_id: backend.id,
        stage: :engineer,
        name: "engineer role",
        model: "claude-3-7-sonnet",
        system_prompt: "You are the engineer agent."
      })

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_str_1", "identifier" => "STR-1", "title" => "Send To Review"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "Send To Review"})
    {:ok, task} = Pipeline.create_task(issue, :engineer)
    # A branch review can read is a branch the remote has, so the worktree here is
    # one that has actually been pushed.
    remote = create_temp_git_repo(prefix: "rail_git_remote", initial_commit: false)
    git!(remote, ["config", "receive.denyCurrentBranch", "ignore"])

    worktree_path = create_temp_git_repo()
    git!(worktree_path, ["remote", "add", "origin", remote])
    git!(worktree_path, ["push", "--set-upstream", "origin", "main"])

    {:ok, task} = Pipeline.update_task(task, %{worktree_path: worktree_path})
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :finished,
        stage_outcome: :in_progress,
        conversation_id: "sess_send_to_review",
        started_at: DateTime.utc_now()
      })

    %{
      backend: backend,
      project: project,
      task: task,
      run: Repo.preload(run, [:task, :role]),
      worktree_path: worktree_path
    }
  end

  # The brief the reviewer is spawned with never reaches its log, so without this
  # the change comes back round with nothing in the conversation marking that it
  # did.
  test "the reviewer's log says the change came back", %{backend: backend, project: project, task: task, run: run} do
    {:ok, review_role} =
      Roles.create_role(system_scope(), project, %{
        backend_id: backend.id,
        stage: :review,
        name: "review role",
        model: "claude-3-7-sonnet",
        system_prompt: "You are the review agent."
      })

    {:ok, review_run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: review_role.id,
        status: :finished,
        stage_outcome: :done,
        conversation_id: "sess_send_to_review_review",
        started_at: DateTime.utc_now()
      })

    assert {:ok, %Run{}} = Pipeline.send_to_review(run)

    log = review_run |> Pipeline.list_run_events() |> Enum.map_join("\n", & &1.line)

    assert log =~ "[human] The engineer has worked on your findings and pushed the change again."
    assert log =~ "a fix can be wrong, or right and break something next to it"
    assert log =~ "whether it has been addressed"
  end

  # A reviewer that has never run has no conversation for this to be the next
  # thing in: its first turn is the brief.
  test "a reviewer that has never run gets no such line", %{run: run} do
    assert {:ok, %Run{}} = Pipeline.send_to_review(run)

    assert [%Run{}] = Repo.all(Run)
    assert Repo.all(Rail.Pipeline.Schemas.RunEvent) == []
  end

  test "hands the task to review and latches the engineer run", %{task: task, run: run} do
    assert {:ok, %Run{stage_outcome: :done}} = Pipeline.send_to_review(run)
    assert %Task{stage: :review} = Repo.reload!(task)
  end

  test "refuses work nobody has committed", %{task: task, run: run, worktree_path: repo} do
    File.write!(Path.join(repo, "uncommitted.ex"), "one\n")

    assert {:error, :uncommitted_changes} = Pipeline.send_to_review(run)
    assert %Task{stage: :engineer} = Repo.reload!(task)
  end

  # A commit nobody else can see is not a change anyone can review.
  test "refuses commits the remote has never been told about", %{task: task, run: run, worktree_path: repo} do
    File.write!(Path.join(repo, "local.ex"), "one\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "never pushed"])

    assert {:error, :unpushed_changes} = Pipeline.send_to_review(run)
    assert %Task{stage: :engineer} = Repo.reload!(task)
  end

  test "refuses while something is still running on the task", %{task: task, run: run} do
    {:ok, _running} = Pipeline.update_run(run, %{status: :running})

    assert {:error, :stage_running} = Pipeline.send_to_review(run)
    assert %Task{stage: :engineer} = Repo.reload!(task)
  end

  test "refuses a task that has not reached engineer", %{task: task, run: run} do
    {:ok, _moved} = Pipeline.update_task(task, %{stage: :architect})

    assert {:error, {:invalid_stage, :architect}} = Pipeline.send_to_review(run)
  end

  test "a project with CI sends nothing to review that CI has not passed", %{project: project, task: task, run: run} do
    {:ok, _project} = Projects.update_project(system_scope(), project, %{ci_command: "mise run ci"})

    assert {:error, :ci_not_passed} = Pipeline.send_to_review(run)
    assert %Task{stage: :engineer} = Repo.reload!(task)
  end

  test "a pass for an earlier commit is not a pass for this one", %{
    project: project,
    run: run,
    worktree_path: worktree_path
  } do
    {:ok, _project} = Projects.update_project(system_scope(), project, %{ci_command: "mise run ci"})

    %OsProcess{}
    |> OsProcess.changeset(%{
      run_id: run.id,
      task_id: run.task_id,
      kind: :ci,
      head_sha: "0000000000000000000000000000000000000000",
      exit_code: 0,
      stream_path: "/tmp/#{run.id}.log",
      status: :finished,
      started_at: DateTime.utc_now()
    })
    |> Repo.insert!()

    assert {:error, :ci_not_passed} = Pipeline.send_to_review(run)

    %OsProcess{}
    |> OsProcess.changeset(%{
      run_id: run.id,
      task_id: run.task_id,
      kind: :ci,
      head_sha: String.trim(git!(worktree_path, ["rev-parse", "HEAD"])),
      exit_code: 0,
      stream_path: "/tmp/#{run.id}-again.log",
      status: :finished,
      started_at: DateTime.utc_now()
    })
    |> Repo.insert!()

    assert {:ok, %Run{stage_outcome: :done}} = Pipeline.send_to_review(run)
  end

  test "a task past engineer goes back to review for what the engineer changed since", %{
    backend: backend,
    project: project,
    task: task,
    run: run,
    worktree_path: worktree_path
  } do
    {:ok, review_role} =
      Roles.create_role(system_scope(), project, %{
        backend_id: backend.id,
        stage: :review,
        name: "review role",
        model: "claude-3-7-sonnet",
        system_prompt: "You are the review agent."
      })

    reviewed = String.trim(git!(worktree_path, ["rev-parse", "HEAD"]))

    {:ok, _review_run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: review_role.id,
        status: :finished,
        stage_outcome: :done,
        stage_fingerprint_head_sha: reviewed,
        started_at: DateTime.utc_now()
      })

    {:ok, task} = Pipeline.update_task(task, %{stage: :demo})

    assert {:error, :nothing_new_to_review} = Pipeline.send_to_review(run)
    refute Pipeline.changed_since_review?(task)

    File.write!(Path.join(worktree_path, "resolved.ex"), "both\n")
    git!(worktree_path, ["add", "."])
    git!(worktree_path, ["commit", "-m", "resolve the rebase"])
    git!(worktree_path, ["push", "origin", "main"])

    assert Pipeline.changed_since_review?(task)
    stub(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)

    assert {:ok, %Run{}} = Pipeline.send_to_review(run)
    assert %Task{stage: :review} = Repo.reload!(task)
  end

  test "a task never reviewed has changed since review", %{task: task} do
    assert Pipeline.changed_since_review?(task)
  end
end
