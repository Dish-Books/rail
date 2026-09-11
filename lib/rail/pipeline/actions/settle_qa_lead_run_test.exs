defmodule Rail.Pipeline.Actions.SettleQaLeadRunTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Runs
  alias Rail.Runs.Schemas.RoleRun
  alias Rail.Runs.Schemas.Run
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    {:ok, backend} =
      Rail.Backends.create_backend(system_scope(), %{name: :claude, executable_path: "/usr/bin/true"})

    scope = system_scope()

    {:ok, workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Settle QA Lead Workspace",
        external_id: "lin_ws_settle_qa_lead",
        token: "lin_api_token_settle_qa_lead",
        webhook_secret: "whsec_settle_qa_lead"
      })

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Settle QA Lead Project 14607",
        github_repo: "org/settle-qa-lead-14607",
        github_installation_id: 14_607,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_settle_qa_lead_14607",
        linear_team_key: "P14607",
        default_branch: "main",
        clone_path: "/tmp/repos/settle-qa-lead-14607",
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
            backend_id: backend.id,
            stage: stage,
            name: "#{stage} role",
            model: "claude-3-7-sonnet",
            system_prompt: "You are the #{stage} agent."
          })

        {stage, role}
      end)

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_settle_qa_lead_1",
      "identifier" => "S14607-1",
      "title" => "Settle QA Lead Issue"
    })

    {:ok, issue} = Issues.capture_issue(scope, project, "Settle QA Lead Issue")

    {:ok, task} = Pipeline.create_task(issue, :product)

    # These tests exercise stage transitions, not Linear publishing.
    {:ok, task} = Pipeline.update_task(scope, task.id, %{issue_id: nil})

    %{backend: backend, project: project, issue: issue, task: task, roles: roles}
  end

  test "settles clean exit 0 for qa_lead stage with passed verdict advancing to demo if configured", %{
    task: task,
    roles: roles
  } do
    {:ok, role_lead} =
      Roles.update_role(system_scope(), roles[:qa_lead], %{
        name: "QA Lead"
      })

    {:ok, _role_demo} =
      Roles.update_role(system_scope(), roles[:demo], %{
        name: "Demo Recorder"
      })

    {:ok, %Task{id: task_id} = _task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :qa_lead,
        stage_state: :running
      })

    {:ok, role_run} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: role_lead.id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    output = "QA Lead evaluation successful.\n\nVERDICT: PASSED"

    Runs.append_run_event(role_run, output)

    run =
      %Run{}
      |> Run.changeset(%{
        role_run_id: role_run.id,
        task_id: role_run.task_id,
        kind: :stage,
        stream_path: "/tmp/settle_qa_lead/#{role_run.id}.ndjson",
        node: to_string(Node.self()),
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    {:ok, _settled_task, _settled_role_run} = Pipeline.settle_run(run, %{exit_code: 0})

    assert {:ok,
            %Task{
              id: ^task_id,
              stage: :demo,
              stage_state: :queued
            }, %RoleRun{status: :finished}} =
             Pipeline.settle_qa_lead_run(run)
  end

  test "settles clean exit 0 for qa_lead stage with passed verdict advancing to ready_to_merge if no demo role", %{
    task: task,
    roles: roles
  } do
    {:ok, _deleted} = Roles.delete_role(system_scope(), roles[:demo])

    {:ok, role_lead} =
      Roles.update_role(system_scope(), roles[:qa_lead], %{
        name: "QA Lead"
      })

    {:ok, %Task{id: task_id} = _task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :qa_lead,
        stage_state: :running
      })

    {:ok, role_run} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: role_lead.id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    output = "QA Lead evaluation successful.\n\nVERDICT: APPROVED"

    Runs.append_run_event(role_run, output)

    run =
      %Run{}
      |> Run.changeset(%{
        role_run_id: role_run.id,
        task_id: role_run.task_id,
        kind: :stage,
        stream_path: "/tmp/settle_qa_lead/#{role_run.id}.ndjson",
        node: to_string(Node.self()),
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    {:ok, _settled_task, _settled_role_run} = Pipeline.settle_run(run, %{exit_code: 0})

    assert {:ok,
            %Task{
              id: ^task_id,
              stage: :ready_to_merge,
              stage_state: :awaiting_approval
            }, %RoleRun{status: :finished}} =
             Pipeline.settle_qa_lead_run(run)
  end
end
