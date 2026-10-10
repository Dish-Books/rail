defmodule Rail.Pipeline.Utils.EngineerRunFinishedTest do
  use Rail.DataCase, async: true

  import Rail.Pipeline.Utils.EngineerRunFinished

  alias Rail.Git
  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Roles

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
    worktree_path = create_temp_git_repo()
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

  test "a turn that committed hands its commits over", %{run: %Run{id: run_id} = run} do
    expect(Pipeline, :hand_over_work, fn _scope, %Run{id: ^run_id} = run -> {:ok, %{run | status: :running}} end)

    assert %Run{id: ^run_id, status: :running} = engineer_run_finished(run, [])
  end

  test "a turn whose commits could not be sent on says why and moves nothing", %{task: task, run: run} do
    expect(Pipeline, :hand_over_work, fn _scope, _run -> {:error, "remote rejected"} end)

    assert %Run{error: "The engineer's commits could not be sent on: remote rejected"} = engineer_run_finished(run, [])
    assert %Task{stage: :engineer} = Repo.reload!(task)
  end

  test "a turn refused a hand-over says why", %{run: run} do
    expect(Pipeline, :hand_over_work, fn _scope, _run -> {:error, {:invalid_stage, :review}} end)

    assert %Run{error: "The engineer's commits could not be sent on: {:invalid_stage, :review}"} =
             engineer_run_finished(run, [])
  end

  # Work left uncommitted is not the engineer's hand-over, so it waits for the turn that commits it.
  test "a turn that committed nothing new leaves the stage open", %{run: run, worktree_path: repo} do
    File.write!(Path.join(repo, "feature.ex"), "one\n")
    stub(Git, :branch_unpushed?, fn _path -> false end)
    reject(&Pipeline.hand_over_work/2)

    assert {:open, %Run{error: nil}} = engineer_run_finished(run, [])
  end

  test "a turn whose worktree is gone leaves the stage open", %{task: task, run: run} do
    reject(&Pipeline.hand_over_work/2)

    assert {:open, %Run{}} = engineer_run_finished(%{run | task: %{task | worktree_path: "/nonexistent/efn"}}, [])
  end
end
