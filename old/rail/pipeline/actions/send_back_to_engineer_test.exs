defmodule Rail.Pipeline.Actions.SendBackToEngineerTest do
  use Rail.DataCase, async: true

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
        name: "Send Back Workspace",
        external_id: "lin_ws_send_back",
        token: "lin_api_token_send_back",
        webhook_secret: "whsec_send_back"
      })

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Send Back Project 8401",
        github_repo: "org/send-back-8401",
        github_installation_id: 8401,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_send_back_8401",
        linear_team_key: "P8401",
        default_branch: "main",
        clone_path: "/tmp/repos/send-back-8401",
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
      "id" => "lin_send_back_1",
      "identifier" => "SBE-1",
      "title" => "Send Back Issue"
    })

    {:ok, issue} = Issues.create_issue(project, %{description: "Send Back Issue"})

    {:ok, task} = Pipeline.create_task(issue, :product)

    %{project: project, issue: issue, task: task, roles: roles}
  end

  test "refuses while the stage's run is still working", %{task: task, roles: roles} do
    {:ok, task} = Pipeline.update_task(task, %{stage: :review})

    {:ok, _running} =
      Runs.create_run(%{
        task_id: task.id,
        role_id: roles[:review].id,
        status: :running,
        started_at: DateTime.utc_now()
      })

    assert {:error, :stage_running} = Pipeline.send_back_to_engineer(task)
  end

  test "returns stage_before_engineer for product, design, and architect stages", %{project: project, task: task} do
    {:ok, t_prod} =
      Pipeline.update_task(task, %{
        stage: :product
      })

    assert {:error, :stage_before_engineer} = Pipeline.send_back_to_engineer(t_prod)

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_send_back_8402",
      "identifier" => "TSK-8402",
      "title" => "Task 8402"
    })

    {:ok, issue_8402} = Issues.create_issue(project, %{description: "Task 8402"})

    {:ok, t_des} = Pipeline.create_task(issue_8402, :product)

    {:ok, t_des} =
      Pipeline.update_task(t_des, %{
        stage: :design
      })

    assert {:error, :stage_before_engineer} = Pipeline.send_back_to_engineer(t_des)

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_send_back_8403",
      "identifier" => "TSK-8403",
      "title" => "Task 8403"
    })

    {:ok, issue_8403} = Issues.create_issue(project, %{description: "Task 8403"})

    {:ok, t_arch} = Pipeline.create_task(issue_8403, :product)

    {:ok, t_arch} =
      Pipeline.update_task(t_arch, %{
        stage: :architect
      })

    assert {:error, :stage_before_engineer} = Pipeline.send_back_to_engineer(t_arch)
  end

  test "returns task_merged when task is in merged stage", %{task: task} do
    {:ok, task} =
      Pipeline.update_task(task, %{
        stage: :merged
      })

    assert {:error, :task_merged} = Pipeline.send_back_to_engineer(task)
  end

  test "returns no_engineer_role when project lacks an engineer role", %{task: task, roles: roles} do
    {:ok, _deleted} = Roles.delete_role(system_scope(), roles[:engineer])

    {:ok, task} =
      Pipeline.update_task(task, %{
        stage: :review
      })

    assert {:error, :no_engineer_role} = Pipeline.send_back_to_engineer(task)
  end

  test "grants fresh budget, collects gate reports, and queues engineer with pending answer", %{task: task, roles: roles} do
    {:ok, role_eng} =
      Roles.update_role(system_scope(), roles[:engineer], %{
        name: "Staff Engineer"
      })

    {:ok, role_rev} =
      Roles.update_role(system_scope(), roles[:review], %{
        name: "Lead Reviewer"
      })

    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(task, %{
        stage: :review,
        rework_cycles: 4,
        rework_budget_base: 0,
        rework_cycles_by_gate: %{role_rev.id => 3},
        outstanding_reports: [role_rev.id]
      })

    {:ok, rev_run} =
      Runs.create_run(%{
        task_id: task_id,
        role_id: role_rev.id,
        conversation_id: "sess_fixture",
        status: :finished,
        started_at: DateTime.utc_now()
      })

    Runs.append_run_event(rev_run, "Reviewer finding: memory leak in loop.")

    {:ok, _eng_run} =
      Runs.create_run(%{
        task_id: task_id,
        role_id: role_eng.id,
        conversation_id: "sess_eng",
        status: :finished,
        started_at: DateTime.utc_now()
      })

    expected_empty = %{}

    assert {:ok,
            %Task{
              id: ^task_id,
              stage: :engineer,
              rework_cycles: 4,
              rework_budget_base: 4,
              rework_cycles_by_gate: ^expected_empty,
              outstanding_reports: []
            }} = Pipeline.send_back_to_engineer(task, comment: "Please address memory leak.")

    eng_run = Repo.one(from r in Run, where: r.task_id == ^task_id and r.role_id == ^role_eng.id)
    assert eng_run.pending_answer =~ "Sent back to you by the human"
    assert eng_run.pending_answer =~ "What the human asked for:\n\nPlease address memory leak."
    assert eng_run.pending_answer =~ "### Lead Reviewer\n\nReviewer finding: memory leak in loop."
  end

  test "supports string comment directly or empty note", %{task: task, roles: roles} do
    {:ok, role_eng} =
      Roles.update_role(system_scope(), roles[:engineer], %{
        name: "Staff Engineer"
      })

    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(task, %{
        stage: :qa
      })

    {:ok, _eng_run} =
      Runs.create_run(%{
        task_id: task_id,
        role_id: role_eng.id,
        conversation_id: "sess_eng",
        status: :finished,
        started_at: DateTime.utc_now()
      })

    assert {:ok, %Task{stage: :engineer}} =
             Pipeline.send_back_to_engineer(task, "Direct string comment")

    eng_run = Repo.one(from r in Run, where: r.task_id == ^task_id and r.role_id == ^role_eng.id)
    assert eng_run.pending_answer =~ "What the human asked for:\n\nDirect string comment"
  end

  test "returns no_session when the engineer has never held a conversation", %{task: task, roles: roles} do
    {:ok, role_eng} = Roles.update_role(system_scope(), roles[:engineer], %{name: "Staff Engineer"})

    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(task, %{
        stage: :qa
      })

    assert {:error, :no_session} = Pipeline.send_back_to_engineer(task, "Please fix")

    assert Repo.one(from r in Run, where: r.task_id == ^task_id and r.role_id == ^role_eng.id) == nil
  end
end
