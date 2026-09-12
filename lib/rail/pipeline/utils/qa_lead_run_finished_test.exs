defmodule Rail.Pipeline.Utils.QaLeadRunFinishedTest do
  use Rail.DataCase, async: true

  import Rail.Pipeline.Utils.QaLeadRunFinished

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Runs
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
    {:ok, task} = Pipeline.update_task(task, %{issue_id: nil})

    {:ok, task} = Pipeline.update_task(task, %{stage: :qa_lead})

    {:ok, run} =
      Runs.create_run(%{
        task_id: task.id,
        role_id: roles[:qa_lead].id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    run = Repo.preload(run, [:task, :role])

    %{backend: backend, project: project, issue: issue, task: task, roles: roles, run: run}
  end

  test "a pass goes to demo when the project has one", %{task: task, run: run} do
    Runs.append_run_event(run, "QA Lead evaluation successful.\n\nVERDICT: PASSED")

    assert %Run{} = qa_lead_run_finished(run, [])
    assert %Task{stage: :demo} = Repo.get!(Task, task.id)
  end

  test "a pass goes straight to the merge when there is no demo role", %{task: task, run: run, roles: roles} do
    {:ok, _deleted} = Roles.delete_role(system_scope(), roles[:demo])
    Runs.append_run_event(run, "QA Lead evaluation successful.\n\nVERDICT: APPROVED")

    assert %Run{} = qa_lead_run_finished(run, [])
    assert %Task{stage: :ready_to_merge} = Repo.get!(Task, task.id)
  end

  test "changes requested sends the change back to the engineer", %{task: task, run: run} do
    Runs.append_run_event(run, "Two things are still wrong.\n\nVERDICT: CHANGES REQUESTED")

    assert %Run{} = qa_lead_run_finished(run, [])
    assert %Task{stage: :engineer, rework_cycles: 1} = Repo.get!(Task, task.id)
  end
end
