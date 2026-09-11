defmodule Rail.Pipeline.Actions.SendBackToEngineerTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Runs
  alias Rail.Runs.Schemas.RoleRun
  alias Rail.Scope
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
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

    {:ok, issue} = Issues.capture_issue(scope, project, "Send Back Issue")

    {:ok, task} = Pipeline.create_task(issue, :product)

    %{project: project, issue: issue, task: task, roles: roles}
  end

  test "returns not_found when task cannot be resolved" do
    assert {:error, :not_found} = Pipeline.send_back_to_engineer("tsk_000000000000000000000000")
  end

  test "returns not_authorized when scope lacks permission", %{task: task} do
    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :review,
        stage_state: :awaiting_approval
      })

    unauth_scope = %Scope{user: nil, system: false}

    assert {:error, :not_authorized} = Pipeline.send_back_to_engineer(unauth_scope, task.id, [])
  end

  test "returns task_running when task is currently running", %{task: task} do
    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :review,
        stage_state: :running
      })

    assert {:error, :task_running} = Pipeline.send_back_to_engineer(task)
  end

  test "returns stage_before_engineer for product, design, and architect stages", %{project: project, task: task} do
    {:ok, t_prod} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :product,
        stage_state: :awaiting_approval
      })

    assert {:error, :stage_before_engineer} = Pipeline.send_back_to_engineer(t_prod)

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_send_back_8402",
      "identifier" => "TSK-8402",
      "title" => "Task 8402"
    })

    {:ok, issue_8402} = Issues.capture_issue(system_scope(), project, "Task 8402")

    {:ok, t_des} = Pipeline.create_task(issue_8402, :product)

    {:ok, t_des} =
      Pipeline.update_task(system_scope(), t_des.id, %{
        stage: :design,
        stage_state: :awaiting_approval
      })

    assert {:error, :stage_before_engineer} = Pipeline.send_back_to_engineer(t_des)

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_send_back_8403",
      "identifier" => "TSK-8403",
      "title" => "Task 8403"
    })

    {:ok, issue_8403} = Issues.capture_issue(system_scope(), project, "Task 8403")

    {:ok, t_arch} = Pipeline.create_task(issue_8403, :product)

    {:ok, t_arch} =
      Pipeline.update_task(system_scope(), t_arch.id, %{
        stage: :architect,
        stage_state: :awaiting_approval
      })

    assert {:error, :stage_before_engineer} = Pipeline.send_back_to_engineer(t_arch)
  end

  test "returns task_merged when task is in merged stage", %{task: task} do
    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :merged,
        stage_state: :awaiting_approval
      })

    assert {:error, :task_merged} = Pipeline.send_back_to_engineer(task)
  end

  test "returns no_engineer_role when project lacks an engineer role", %{task: task, roles: roles} do
    {:ok, _deleted} = Roles.delete_role(system_scope(), roles[:engineer])

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :review,
        stage_state: :awaiting_approval
      })

    assert {:error, :no_engineer_role} = Pipeline.send_back_to_engineer(task)
  end

  test "grants fresh budget, collects gate reports, and queues engineer with pending answer", %{task: task, roles: roles} do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")

    {:ok, role_eng} =
      Roles.update_role(system_scope(), roles[:engineer], %{
        name: "Staff Engineer"
      })

    {:ok, role_rev} =
      Roles.update_role(system_scope(), roles[:review], %{
        name: "Lead Reviewer"
      })

    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :review,
        stage_state: :awaiting_approval,
        rework_cycles: 4,
        rework_budget_base: 0,
        rework_cycles_by_gate: %{role_rev.id => 3},
        outstanding_reports: [role_rev.id],
        error: "Rework limit reached"
      })

    {:ok, _role_run} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: role_rev.id,
        conversation_id: "sess_fixture",
        status: :finished,
        started_at: DateTime.utc_now(),
        output: "Reviewer finding: memory leak in loop."
      })

    {:ok, _eng_run} =
      Runs.create_role_run(%{
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
              stage_state: :queued,
              rework_cycles: 4,
              rework_budget_base: 4,
              rework_cycles_by_gate: ^expected_empty,
              outstanding_reports: [],
              error: nil
            }} = Pipeline.send_back_to_engineer(task, comment: "Please address memory leak.")

    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :sent_back_to_engineer}}

    eng_run = Repo.one(from r in RoleRun, where: r.task_id == ^task_id and r.role_id == ^role_eng.id)
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
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :qa,
        stage_state: :awaiting_approval
      })

    {:ok, _eng_run} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: role_eng.id,
        conversation_id: "sess_eng",
        status: :finished,
        started_at: DateTime.utc_now()
      })

    assert {:ok, %Task{stage: :engineer, stage_state: :queued}} =
             Pipeline.send_back_to_engineer(task, "Direct string comment")

    eng_run = Repo.one(from r in RoleRun, where: r.task_id == ^task_id and r.role_id == ^role_eng.id)
    assert eng_run.pending_answer =~ "What the human asked for:\n\nDirect string comment"
  end

  test "appends to existing engineer pending_answer, authorizes user scope, and handles non-list note", %{
    task: task,
    roles: roles
  } do
    {:ok, role_eng} =
      Roles.update_role(system_scope(), roles[:engineer], %{
        name: "Staff Engineer"
      })

    user_scope = %Scope{user: %{id: "usr_test"}, system: false}

    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :review,
        stage_state: :awaiting_approval
      })

    {:ok, _role_run} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: role_eng.id,
        conversation_id: "sess_fixture",
        status: :finished,
        started_at: DateTime.utc_now(),
        pending_answer: "Initial engineer instruction"
      })

    assert {:ok, %Task{stage: :engineer, stage_state: :queued}} =
             Pipeline.send_back_to_engineer(user_scope, task.id)

    assert {:ok, %Task{stage: :engineer, stage_state: :queued}} =
             Pipeline.send_back_to_engineer(user_scope, task.id, comment: nil)

    assert {:ok, %Task{stage: :engineer, stage_state: :queued}} =
             Pipeline.send_back_to_engineer(task, :non_list_opts)

    eng_run = Repo.one(from r in RoleRun, where: r.task_id == ^task_id and r.role_id == ^role_eng.id)
    assert eng_run.pending_answer =~ "Initial engineer instruction\n\nSent back to you by the human"

    assert {:error, :not_found} = Pipeline.send_back_to_engineer(user_scope, :invalid_task)
  end

  test "returns no_session when the engineer has never held a conversation", %{task: task, roles: roles} do
    {:ok, role_eng} = Roles.update_role(system_scope(), roles[:engineer], %{name: "Staff Engineer"})

    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :qa,
        stage_state: :awaiting_approval
      })

    assert {:error, :no_session} = Pipeline.send_back_to_engineer(task, "Please fix")

    assert Repo.one(from r in RoleRun, where: r.task_id == ^task_id and r.role_id == ^role_eng.id) == nil
  end
end
