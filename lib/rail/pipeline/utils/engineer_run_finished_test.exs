defmodule Rail.Pipeline.Utils.EngineerRunFinishedTest do
  use Rail.DataCase, async: true

  import Rail.Pipeline.Utils.EngineerRunFinished

  alias Rail.Git
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

    {:ok, role} = Roles.get_role(project_id: project.id, stage: :engineer)

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_efn_1", "identifier" => "EFN-1", "title" => "Engineer Finished"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "Engineer Finished"})
    {:ok, task} = Pipeline.create_task(issue, :engineer)
    # Whether the turn committed or left work is asked of Rail.Git, so the worktree is a plain directory and each
    # test says what the stubs answer.
    worktree_path = Path.join(task.scratch_path, "worktree")
    File.mkdir_p!(worktree_path)
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: worktree_path})
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :running,
        conversation_id: "sess_engineer_finished",
        started_at: DateTime.utc_now()
      })

    %{
      task: task,
      run: Repo.preload(run, [:task, :role]),
      worktree_path: worktree_path
    }
  end

  test "a turn that committed hands its commits over", %{run: %Run{id: run_id} = run, worktree_path: worktree_path} do
    expect(Git, :branch_unpushed?, fn ^worktree_path -> true end)
    expect(Pipeline, :hand_over_work, fn _scope, %Run{id: ^run_id} = run -> {:ok, %{run | status: :running}} end)

    assert %Run{id: ^run_id, status: :running} = engineer_run_finished(run, [])
  end

  test "a turn whose commits could not be sent on, or whose hand-over was refused, says why and moves nothing", %{
    task: task,
    run: run
  } do
    stub(Git, :branch_unpushed?, fn _path -> true end)
    expect(Pipeline, :hand_over_work, fn _scope, _run -> {:error, "remote rejected"} end)

    assert %Run{error: "The engineer's commits could not be sent on: remote rejected"} = engineer_run_finished(run, [])
    assert %Task{stage: :engineer} = Repo.reload!(task)

    expect(Pipeline, :hand_over_work, fn _scope, _run -> {:error, {:invalid_stage, :review}} end)

    assert %Run{error: "The engineer's commits could not be sent on: {:invalid_stage, :review}"} =
             engineer_run_finished(run, [])
  end

  # Rail never force-pushes, so a branch it will not push goes back to the engineer to merge.
  test "a turn whose branch rewrote what was pushed goes back to the engineer", %{run: %Run{id: run_id} = run} do
    stub(Git, :branch_unpushed?, fn _path -> true end)
    stub(Git, :get_or_create_worktree, fn _project, task -> {:ok, task.worktree_path} end)
    expect(Pipeline, :hand_over_work, fn _scope, _run -> {:error, :history_rewritten} end)

    expect(Tools, :start_os_process, fn %Run{id: ^run_id} = spawned, ["-p", prompt | _rest] ->
      assert prompt =~ "so Rail did not push it"
      {:ok, %OsProcess{run: spawned}}
    end)

    assert %Run{id: ^run_id, error: nil} = engineer_run_finished(run, [])
  end

  # Work left uncommitted is not the engineer's hand-over, so it waits for the turn that commits it.
  test "a turn that committed nothing new leaves the stage open", %{task: task, run: run, worktree_path: worktree_path} do
    {:ok, _first} = Pipeline.create_round(task)
    {:ok, _second} = Pipeline.create_round(task)
    stub(Git, :branch_unpushed?, fn _path -> false end)
    expect(Git, :worktree_dirty?, fn ^worktree_path -> true end)
    reject(&Pipeline.hand_over_work/2)
    reject(&Pipeline.send_to_review/1)

    assert {:open, %Run{error: nil}} = engineer_run_finished(run, [])
  end

  # The first round is the ticket's own change, so a turn that left nothing is one answering a message.
  test "a first-round turn that left nothing to send leaves the stage open", %{task: task, run: run} do
    {:ok, _first} = Pipeline.create_round(task)
    stub(Git, :branch_unpushed?, fn _path -> false end)
    stub(Git, :worktree_dirty?, fn _path -> false end)
    reject(&Pipeline.send_to_review/1)

    assert {:open, %Run{error: nil}} = engineer_run_finished(run, [])
  end

  test "a later round that changed no code goes to review as it stands", %{task: task, run: %Run{id: run_id} = run} do
    {:ok, _first} = Pipeline.create_round(task)
    {:ok, _second} = Pipeline.create_round(task)
    stub(Git, :branch_unpushed?, fn _path -> false end)
    stub(Git, :worktree_dirty?, fn _path -> false end)
    expect(Pipeline, :send_to_review, fn %Run{id: ^run_id} = run -> {:ok, %{run | stage_outcome: :done}} end)

    assert %Run{id: ^run_id, stage_outcome: :done} = engineer_run_finished(run, [])
  end

  # A queued message is the engineer about to work again, so the round is not over yet.
  test "a later round with a message queued leaves the stage open", %{task: task, run: run} do
    {:ok, _first} = Pipeline.create_round(task)
    {:ok, _second} = Pipeline.create_round(task)
    stub(Git, :branch_unpushed?, fn _path -> false end)
    reject(&Pipeline.send_to_review/1)

    assert {:open, %Run{}} = engineer_run_finished(%{run | pending_chat: "Also retake the empty state."}, [])
  end

  test "a later round whose HEAD has not passed CI runs CI, with review to follow a pass",
       %{project: project, task: task, run: %Run{id: run_id} = run} do
    {:ok, _project} = Projects.update_project(system_scope(), project, %{ci_command: "mise run ci"})
    {:ok, _first} = Pipeline.create_round(task)
    {:ok, _second} = Pipeline.create_round(task)
    head = String.duplicate("a", 40)
    stub(Git, :branch_unpushed?, fn _path -> false end)
    stub(Git, :worktree_dirty?, fn _path -> false end)
    stub(Git, :branch_fingerprint, fn _path -> %{head_sha: head, dirty_digest: "clean"} end)
    stub(Git, :credential_env, fn _project -> {:ok, %{"RAIL_GIT_TOKEN" => "ghs_token"}} end)
    expect(Pipeline, :send_to_review, fn _run -> {:error, :ci_not_passed} end)

    expect(Tools, :start_command_process, fn %Run{id: ^run_id} = spawned, :ci, "mise run ci", opts ->
      assert opts[:head_sha] == head
      {:ok, %OsProcess{kind: :ci, run: spawned}}
    end)

    assert %Run{id: ^run_id, status: :running, review_on_ci_pass: true} = engineer_run_finished(run, [])
  end

  test "a later round whose CI could not start says why", %{project: project, task: task, run: run} do
    {:ok, _project} = Projects.update_project(system_scope(), project, %{ci_command: "mise run ci"})
    {:ok, _first} = Pipeline.create_round(task)
    {:ok, _second} = Pipeline.create_round(task)
    stub(Git, :branch_unpushed?, fn _path -> false end)
    stub(Git, :worktree_dirty?, fn _path -> false end)
    stub(Git, :branch_fingerprint, fn _path -> %{head_sha: String.duplicate("a", 40), dirty_digest: "clean"} end)
    stub(Git, :credential_env, fn _project -> {:ok, %{"RAIL_GIT_TOKEN" => "ghs_token"}} end)
    expect(Pipeline, :send_to_review, fn _run -> {:error, :ci_not_passed} end)
    expect(Tools, :start_command_process, fn _run, :ci, _command, _opts -> {:error, {:bad_cwd, "/gone"}} end)

    assert %Run{error: "Could not start CI: {:bad_cwd, \"/gone\"}", review_on_ci_pass: false} =
             engineer_run_finished(run, [])
  end

  test "a later round refused review says why", %{task: task, run: run} do
    {:ok, _first} = Pipeline.create_round(task)
    {:ok, _second} = Pipeline.create_round(task)
    stub(Git, :branch_unpushed?, fn _path -> false end)
    stub(Git, :worktree_dirty?, fn _path -> false end)
    expect(Pipeline, :send_to_review, fn _run -> {:error, :stage_running} end)

    assert %Run{error: "The round committed nothing new, but it was not sent to review: :stage_running"} =
             engineer_run_finished(run, [])
  end

  test "a turn whose worktree is gone leaves the stage open", %{task: task, run: run} do
    reject(&Pipeline.hand_over_work/2)

    assert {:open, %Run{}} = engineer_run_finished(%{run | task: %{task | worktree_path: "/nonexistent/efn"}}, [])
  end
end
