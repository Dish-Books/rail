defmodule Rail.Pipeline.Utils.PrepareTurnTest do
  use Rail.DataCase, async: true

  import Rail.Pipeline.Utils.PrepareTurn

  alias Rail.Git
  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Roles

  @moduletag :real_prepare_turn

  setup %{project: project} do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_ptn_1", "identifier" => "PTN-1", "title" => "Prepare Turn"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Prepare Turn"})
    {:ok, task} = Pipeline.create_task(issue, :engineer)
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: create_temp_git_repo()})
    {:ok, role} = Roles.get_role(project_id: project.id, stage: :engineer)

    {:ok, run} =
      Pipeline.create_run(%{task_id: task.id, role_id: role.id, status: :running, started_at: DateTime.utc_now()})

    %{run: %{run | task: task}, task: task}
  end

  test "fetches the default branch into the worktree and sets who it commits as", %{
    run: run,
    task: %Task{id: task_id, worktree_path: worktree_path}
  } do
    expect(Git, :fetch_default_branch, fn %Project{default_branch: "main"}, ^worktree_path -> :ok end)
    expect(Git, :set_commit_identity, fn %Task{id: ^task_id} -> :ok end)

    assert :ok = prepare_turn(run)
    assert [] = Pipeline.list_run_events(run)
  end

  # The agent can still work on the copy it fetched last, so a failure is said rather than stopping the turn.
  test "says in the conversation what it could not do, on one line each, and lets the turn go on", %{run: run} do
    expect(Git, :fetch_default_branch, fn _project, _path -> {:error, "fatal: unable to access\n  origin"} end)
    expect(Git, :set_commit_identity, fn _task -> {:error, "error: could not lock config file"} end)

    assert :ok = prepare_turn(run)

    assert [
             %{
               line:
                 "[rail] Could not fetch origin/main before this turn, so the copy fetched last is what the branch is checked against: fatal: unable to access origin"
             },
             %{
               line:
                 "[rail] Could not set who this turn commits as, so its commits may not be signed: error: could not lock config file"
             }
           ] = Pipeline.list_run_events(run)
  end

  test "says why GitHub would not let it fetch", %{run: run} do
    expect(Git, :fetch_default_branch, fn _project, _path -> {:error, {:github_api_error, 404, %{}}} end)
    expect(Git, :set_commit_identity, fn _task -> :ok end)

    assert :ok = prepare_turn(run)
    assert [%{line: "[rail] Could not fetch origin/main " <> said}] = Pipeline.list_run_events(run)
    assert said =~ "{:github_api_error, 404, %{}}"
  end

  test "leaves a worktree that is gone alone", %{run: %Run{task: task} = run} do
    reject(&Git.fetch_default_branch/2)
    reject(&Git.set_commit_identity/1)

    assert :ok = prepare_turn(%{run | task: %{task | worktree_path: "/nonexistent/ptn"}})
  end
end
