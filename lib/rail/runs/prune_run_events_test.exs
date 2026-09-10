defmodule Rail.Runs.PruneRunEventsTest do
  use Rail.DataCase, async: true

  alias Rail.Domain.TaskUsage
  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Runs
  alias Rail.Runs.Schemas.RoleRun
  alias Rail.Runs.Schemas.RunEvent
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    scope = system_scope()

    {:ok, workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Prune Events Workspace",
        external_id: "lin_ws_prune_events",
        token: "lin_api_token_prune_events",
        webhook_secret: "whsec_prune_events"
      })

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Prune Events Project 10401",
        github_repo: "org/prune-events-10401",
        github_installation_id: 10_401,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_prune_events_10401",
        linear_team_key: "P10401",
        clone_path: "/tmp/repos/prune-events-10401",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    roles =
      Map.new([:product, :design, :architect, :engineer, :review, :qa, :qa_lead, :demo], fn stage ->
        {:ok, role} =
          Roles.create_role(scope, project, %{
            stage: stage,
            name: "#{stage} role",
            model: "claude-3-7-sonnet",
            system_prompt: "You are the #{stage} agent."
          })

        {stage, role}
      end)

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_prune_events_1",
      "identifier" => "PRE-1",
      "title" => "Prune Events Issue"
    })

    {:ok, issue} = Issues.capture_issue(scope, project, "Prune Events Issue")

    LinearMock.mock_update_issue_success(%{"id" => "lin_prune_events_1"})

    {:ok, task} = Pipeline.bring_local(scope, issue)

    %{project: project, issue: issue, task: task, roles: roles}
  end

  test "prunes run_events and marks role_runs older than retention days as pruned", %{task: task, roles: roles} do
    past_date = DateTime.shift(DateTime.utc_now(), week: -5)

    {:ok, role_run} =
      Runs.create_role_run(%{
        task_id: task.id,
        role_id: roles[:engineer].id,
        status: :finished,
        started_at: DateTime.utc_now(),
        completed_at: past_date,
        inserted_at: past_date,
        exit_code: 0,
        output: "Finished old run",
        error: nil,
        usage: %TaskUsage{input_tokens: 200, output_tokens: 100},
        pruned: false
      })

    _run_event = Runs.append_run_event(role_run.id, ~s({"type":"init"}))

    _run_event = Runs.append_run_event(role_run.id, ~s({"type":"output","chunk":"hello"}))

    assert {:ok, %{pruned_events: 2, pruned_role_runs: 1}} = Runs.prune_run_events()

    # Verify events deleted
    assert [] = Repo.all(Ecto.Query.from(e in RunEvent, where: e.role_run_id == ^role_run.id))

    # Verify role_run marked pruned, but metadata preserved
    assert %RoleRun{
             pruned: true,
             exit_code: 0,
             output: "Finished old run",
             error: nil,
             usage: %TaskUsage{input_tokens: 200, output_tokens: 100}
           } = Repo.get!(RoleRun, role_run.id)
  end

  test "preserves recent run_events and leaves recent role_runs unpruned", %{task: task, roles: roles} do
    recent_date = DateTime.shift(DateTime.utc_now(), day: -5)

    {:ok, role_run} =
      Runs.create_role_run(%{
        task_id: task.id,
        role_id: roles[:engineer].id,
        status: :finished,
        started_at: DateTime.utc_now(),
        completed_at: recent_date,
        inserted_at: recent_date,
        exit_code: 0,
        output: "Recent run output",
        pruned: false
      })

    %RunEvent{id: event_id} = Runs.append_run_event(role_run.id, ~s({"type":"recent_event"}))

    assert {:ok, %{pruned_events: 0, pruned_role_runs: 0}} = Runs.prune_run_events()

    assert [%RunEvent{id: ^event_id}] = Repo.all(Ecto.Query.from(e in RunEvent, where: e.role_run_id == ^role_run.id))
    assert %RoleRun{pruned: false} = Repo.get!(RoleRun, role_run.id)
  end

  test "does not prune active in-flight runs even if started past cutoff", %{task: task, roles: roles} do
    past_date = DateTime.shift(DateTime.utc_now(), day: -40)

    {:ok, running_role_run} =
      Runs.create_role_run(%{
        task_id: task.id,
        role_id: roles[:engineer].id,
        status: :running,
        started_at: past_date,
        completed_at: nil,
        inserted_at: past_date,
        pruned: false
      })

    {:ok, starting_role_run} =
      Runs.create_role_run(%{
        task_id: task.id,
        role_id: roles[:engineer].id,
        status: :starting,
        started_at: past_date,
        completed_at: nil,
        inserted_at: past_date,
        pruned: false
      })

    _run_event = Runs.append_run_event(running_role_run.id, ~s({"type":"running_event"}))

    _run_event = Runs.append_run_event(starting_role_run.id, ~s({"type":"starting_event"}))

    assert {:ok, %{pruned_events: 0, pruned_role_runs: 0}} = Runs.prune_run_events()

    assert %RoleRun{pruned: false} = Repo.get!(RoleRun, running_role_run.id)
    assert %RoleRun{pruned: false} = Repo.get!(RoleRun, starting_role_run.id)
  end

  test "supports custom cutoff and retention_days options", %{task: task, roles: roles} do
    past_10_days = DateTime.shift(DateTime.utc_now(), day: -10)

    {:ok, role_run} =
      Runs.create_role_run(%{
        task_id: task.id,
        role_id: roles[:engineer].id,
        status: :finished,
        started_at: DateTime.utc_now(),
        completed_at: past_10_days,
        inserted_at: past_10_days,
        pruned: false
      })

    _run_event = Runs.append_run_event(role_run.id, "log line")

    # Default 30 days leaves 10-day-old run untouched
    assert {:ok, %{pruned_events: 0, pruned_role_runs: 0}} = Runs.prune_run_events()

    # Custom retention of 7 days prunes it
    assert {:ok, %{pruned_events: 1, pruned_role_runs: 1}} =
             Runs.prune_run_events(retention_days: 7)

    assert %RoleRun{pruned: true} = Repo.get!(RoleRun, role_run.id)
  end

  test "idempotent when runs are already pruned", %{task: task, roles: roles} do
    past_date = DateTime.shift(DateTime.utc_now(), day: -50)

    {:ok, role_run} =
      Runs.create_role_run(%{
        task_id: task.id,
        role_id: roles[:engineer].id,
        status: :finished,
        started_at: DateTime.utc_now(),
        completed_at: past_date,
        inserted_at: past_date,
        pruned: true
      })

    assert {:ok, %{pruned_events: 0, pruned_role_runs: 0}} = Runs.prune_run_events()
    assert %RoleRun{pruned: true} = Repo.get!(RoleRun, role_run.id)
  end
end
