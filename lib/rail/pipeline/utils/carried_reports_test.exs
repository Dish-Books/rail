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

  test "returns an empty string when the task has no outstanding reports", %{task: task} do
    {:ok, task} = Pipeline.update_task(task, %{outstanding_reports: []})

    assert carried_reports(task) == ""
  end

  test "carries what each gate's log said, and supports excluding one gate", %{task: task, roles: roles} do
    {:ok, role_rev} = Roles.update_role(system_scope(), roles[:review], %{name: "Reviewer"})
    {:ok, role_qa} = Roles.update_role(system_scope(), roles[:qa], %{name: "QA Tester"})

    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(task, %{
        outstanding_reports: [role_rev.id, role_qa.id]
      })

    {:ok, rev_run} =
      Runs.create_run(%{
        task_id: task_id,
        role_id: role_rev.id,
        status: :finished,
        started_at: DateTime.utc_now()
      })

    Runs.append_run_event(rev_run, "Reviewer finding: unused variable.")

    {:ok, qa_run} =
      Runs.create_run(%{
        task_id: task_id,
        role_id: role_qa.id,
        status: :finished,
        started_at: DateTime.utc_now()
      })

    Runs.append_run_event(qa_run, "QA finding: button alignment broken.")

    text_all = carried_reports(task)
    assert text_all =~ "Also outstanding: what the other gates last reported"
    assert text_all =~ "### Reviewer\n\nReviewer finding: unused variable."
    assert text_all =~ "### QA Tester\n\nQA finding: button alignment broken."

    text_except = carried_reports(task, except: role_rev.id)
    assert text_except =~ "### QA Tester\n\nQA finding: button alignment broken."
    refute text_except =~ "### Reviewer"
  end

  test "leaves out tool, rail and human lines, and gates whose log holds nothing else", %{
    task: task,
    roles: roles
  } do
    {:ok, role} = Roles.update_role(system_scope(), roles[:review], %{name: "Empty Reviewer"})

    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(task, %{outstanding_reports: [role.id]})

    {:ok, run} =
      Runs.create_run(%{
        task_id: task_id,
        role_id: role.id,
        status: :finished,
        started_at: DateTime.utc_now()
      })

    Runs.append_run_event(run, "[tool] bash mix test")
    Runs.append_run_event(run, "[human] take another look")
    Runs.append_run_event(run, "[rail] That turn was not delivered")
    Runs.append_run_event(run, "[result] exit 0")

    assert carried_reports(task) == ""
  end

  test "reads the latest run for a role", %{task: task, roles: roles} do
    {:ok, role} = Roles.update_role(system_scope(), roles[:review], %{name: "Reviewer"})

    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(task, %{outstanding_reports: [role.id]})

    {:ok, first_run} =
      Runs.create_run(%{
        task_id: task_id,
        role_id: role.id,
        status: :finished,
        started_at: DateTime.utc_now()
      })

    Runs.append_run_event(first_run, "Stale finding from the first pass.")

    {:ok, latest_run} =
      Runs.create_run(%{
        task_id: task_id,
        role_id: role.id,
        status: :finished,
        started_at: DateTime.utc_now()
      })

    Runs.append_run_event(latest_run, "Current finding.")

    text = carried_reports(task)
    assert text =~ "Current finding."
    refute text =~ "Stale finding"
  end

  test "falls back to role_id when the role is not in the database", %{task: task} do
    non_existent_role_id = "rol_000000000000000000000001"

    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(task, %{
        outstanding_reports: [non_existent_role_id]
      })

    {:ok, run} =
      Runs.create_run(%{
        task_id: task_id,
        role_id: non_existent_role_id,
        status: :finished,
        started_at: DateTime.utc_now()
      })

    Runs.append_run_event(run, "Finding from unknown role")

    assert carried_reports(task) =~ "### #{non_existent_role_id}\n\nFinding from unknown role"
  end
end
