defmodule Rail.Pipeline.Utils.CarriedReportsTest do
  use Rail.DataCase, async: true

  import Rail.Pipeline.Utils.CarriedReports

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Roles
  alias Rail.Runs
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    {:ok, backend} =
      Rail.Backends.create_backend(system_scope(), %{name: :claude, executable_path: "/usr/bin/true"})

    scope = system_scope()

    {:ok, workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Carried Reports Workspace",
        external_id: "lin_ws_carried_reports",
        token: "lin_api_token_carried_reports",
        webhook_secret: "whsec_carried_reports"
      })

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Carried Reports Project 9801",
        github_repo: "org/carried-reports-9801",
        github_installation_id: 9801,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_carried_reports_9801",
        linear_team_key: "P9801",
        default_branch: "main",
        clone_path: "/tmp/repos/carried-reports-9801",
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
      "id" => "lin_carried_reports_1",
      "identifier" => "CRR-1",
      "title" => "Carried Reports Issue"
    })

    {:ok, issue} = Issues.capture_issue(scope, project, "Carried Reports Issue")

    {:ok, task} = Pipeline.create_task(issue, :product)

    %{project: project, issue: issue, task: task, roles: roles}
  end

  test "returns empty string and empty entries when task has no outstanding reports", %{task: task} do
    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        outstanding_reports: []
      })

    assert build_carried_gate_reports(task) == ""
    assert collect_report_entries(task) == []
  end

  test "formats carried gate reports and supports excluding a specific gate", %{task: task, roles: roles} do
    {:ok, role_rev} =
      Roles.update_role(system_scope(), roles[:review], %{
        name: "Reviewer"
      })

    {:ok, role_qa} =
      Roles.update_role(system_scope(), roles[:qa], %{
        name: "QA Tester"
      })

    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(system_scope(), task.id, %{
        outstanding_reports: [role_rev.id, role_qa.id]
      })

    {:ok, _role_run} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: role_rev.id,
        status: :finished,
        started_at: DateTime.utc_now(),
        output: "Reviewer finding: unused variable."
      })

    {:ok, _role_run} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: role_qa.id,
        status: :finished,
        started_at: DateTime.utc_now(),
        output: "QA finding: button alignment broken."
      })

    text_all = build_carried_gate_reports(task)
    assert text_all =~ "Also outstanding: what the other gates last reported"
    assert text_all =~ "### Reviewer\n\nReviewer finding: unused variable."
    assert text_all =~ "### QA Tester\n\nQA finding: button alignment broken."

    text_except = build_carried_gate_reports(task, except: role_rev.id)
    assert text_except =~ "### QA Tester\n\nQA finding: button alignment broken."
    refute text_except =~ "### Reviewer"
  end

  test "ignores role_runs with empty or missing output", %{task: task, roles: roles} do
    {:ok, role} =
      Roles.update_role(system_scope(), roles[:review], %{
        name: "Empty Reviewer"
      })

    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(system_scope(), task.id, %{
        outstanding_reports: [role.id]
      })

    {:ok, _role_run} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: role.id,
        status: :finished,
        started_at: DateTime.utc_now(),
        output: "   "
      })

    assert build_carried_gate_reports(task) == ""
    assert collect_report_entries(task) == []
  end

  test "falls back to role_id when role schema is not found in database", %{task: task} do
    non_existent_role_id = "rol_000000000000000000000001"

    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(system_scope(), task.id, %{
        outstanding_reports: [non_existent_role_id]
      })

    {:ok, _role_run} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: non_existent_role_id,
        status: :finished,
        started_at: DateTime.utc_now(),
        output: "Finding from unknown role"
      })

    assert [{^non_existent_role_id, ^non_existent_role_id, "Finding from unknown role"}] =
             collect_report_entries(task)

    assert build_carried_gate_reports(task) =~ "### #{non_existent_role_id}\n\nFinding from unknown role"
  end
end
