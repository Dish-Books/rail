defmodule Rail.Pipeline.Actions.EnterStageTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Roles
  alias Rail.Runs
  alias Rail.Runs.Schemas.OsProcess
  alias Rail.Runs.Schemas.Run
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    scope = system_scope()

    {:ok, backend} = Rail.Tools.create_backend(scope, %{name: :claude, executable_path: "/usr/bin/true"})

    {:ok, workspace} =
      Projects.upsert_linear_workspace(scope, %{
        name: "Enter Stage Workspace",
        external_id: "lin_ws_enter_stage",
        token: "lin_api_token_enter_stage",
        webhook_secret: "whsec_enter_stage"
      })

    {:ok, project} =
      Projects.create_project(scope, %{
        name: "Enter Stage Project",
        github_repo: "org/enter-stage",
        github_installation_id: 44_001,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_enter_stage",
        linear_team_key: "ENT",
        default_branch: "main",
        clone_path: "/tmp/repos/enter-stage",
        linear_state_ids: %{"triage" => "st_triage"}
      })

    roles =
      Map.new([:product, :design, :architect, :engineer, :review, :qa, :qa_lead, :demo], fn stage ->
        {:ok, role} =
          Roles.create_role(scope, project, %{
            backend_id: backend.id,
            stage: stage,
            name: "#{stage} role",
            model: "claude-3-7-sonnet",
            system_prompt: "You are the #{stage} agent."
          })

        {stage, role}
      end)

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_enter_stage_1",
      "identifier" => "ENT-1",
      "title" => "Enter Stage Issue"
    })

    {:ok, issue} = Issues.create_issue(project, %{description: "Enter Stage Issue"})
    {:ok, task} = Pipeline.create_task(issue, :product)

    %{project: project, task: task, roles: roles}
  end

  setup %{task: task} do
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: create_temp_git_repo()})

    %{task: task}
  end

  test "writes the stage and starts the run that belongs to it", %{task: task, roles: roles} do
    stub(Runs, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned, task: task}} end)

    %{id: review_role_id} = roles[:review]

    assert {:ok, %Run{role_id: ^review_role_id, status: :running}} = Pipeline.enter_stage(task, :review)
    assert %Task{stage: :review} = Repo.reload!(task)
  end

  test "unlatches a run that had already concluded, so the stage can conclude again", %{
    task: task,
    roles: roles
  } do
    {:ok, done} =
      Runs.create_run(%{
        task_id: task.id,
        role_id: roles[:review].id,
        status: :finished,
        stage_outcome: :done,
        error: "Something went wrong last time.",
        started_at: DateTime.utc_now()
      })

    stub(Runs, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned, task: task}} end)

    assert {:ok, %Run{stage_outcome: :in_progress, error: nil}} = Pipeline.enter_stage(task, :review)
    assert %Run{stage_outcome: :in_progress} = Repo.reload!(done)
  end

  test "a stage no role runs records the move and stops there", %{task: task} do
    assert {:ok, %Task{stage: :ready_to_merge}} = Pipeline.enter_stage(task, :ready_to_merge)
    assert %Task{stage: :ready_to_merge} = Repo.reload!(task)
  end

  test "a worktree Rail cannot make is recorded on the run, not swallowed", %{task: task} do
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: "/tmp/rail-no-such-worktree"})

    assert {:ok, %Run{status: :failed, error: error}} = Pipeline.enter_stage(task, :review)
    assert error =~ "Could not prepare the worktree"
    assert %Task{stage: :review} = Repo.reload!(task)
  end

  test "a spawn that never happens still leaves the stage entered", %{task: task} do
    stub(Runs, :start_os_process, fn _spawned, _argv -> {:error, :dispatch_disabled} end)

    assert {:ok, %Run{}} = Pipeline.enter_stage(task, :review)
    assert %Task{stage: :review} = Repo.reload!(task)
  end

  test "a spawn that fails records the failure on the run", %{task: task} do
    stub(Runs, :start_os_process, fn spawned, _argv ->
      {:ok, failed} = spawned |> Run.changeset(%{error: "No such CLI binary"}) |> Repo.update()
      {:error, {:spawn_failed, :missing_binary, failed}}
    end)

    assert {:ok, %Run{error: "No such CLI binary"}} = Pipeline.enter_stage(task, :review)
  end
end
