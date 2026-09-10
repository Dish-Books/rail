defmodule Rail.Pipeline.QueueTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Queue
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Roles
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    scope = system_scope()

    {:ok, workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Queue Workspace",
        external_id: "lin_ws_queue",
        token: "lin_api_token_queue",
        webhook_secret: "whsec_queue"
      })

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Queue Project 10101",
        github_repo: "org/queue-10101",
        github_installation_id: 10_101,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_queue_10101",
        linear_team_key: "P10101",
        clone_path: "/tmp/repos/queue-10101",
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
      "id" => "lin_queue_1",
      "identifier" => "QUE-1",
      "title" => "Queue Issue"
    })

    {:ok, issue} = Issues.capture_issue(scope, project, "Queue Issue")

    LinearMock.mock_update_issue_success(%{"id" => "lin_queue_1"})

    {:ok, task} = Pipeline.bring_local(scope, issue)

    %{project: project, issue: issue, task: task, roles: roles}
  end

  test "returns empty list when role has no stage and counts active chats", %{project: project, task: task, roles: _roles} do
    {:ok, role} =
      Roles.create_role(system_scope(), project, %{
        name: "Unbound role",
        model: "claude-3-7-sonnet",
        system_prompt: "You are an unbound agent.",
        max_concurrent: 1
      })

    assert [] = Queue.eligible_tasks(project, role)
    assert Queue.current_live_runs_count(project, role) == 0

    {:ok, _chat_task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :engineer,
        stage_state: :idle,
        active_chat_role_id: role.id
      })

    assert Queue.current_live_runs_count(project, role) == 1
    assert Queue.available_slots(project, role) == 0
  end

  test "counts live runs and available slots accurately", %{project: project, task: task, roles: roles} do
    {:ok, role} =
      Roles.update_role(system_scope(), roles[:product], %{
        max_concurrent: 2
      })

    assert Queue.current_live_runs_count(project, role) == 0
    assert Queue.available_slots(project, role) == 2

    # 1. Running task for this stage
    {:ok, _running_task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :product,
        stage_state: :running
      })

    assert Queue.current_live_runs_count(project, role) == 1
    assert Queue.available_slots(project, role) == 1

    # 2. Task with active chat on this role
    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_queue_10102",
      "identifier" => "TSK-10102",
      "title" => "Task 10102"
    })

    {:ok, issue_10102} = Issues.capture_issue(system_scope(), project, "Task 10102")

    LinearMock.mock_update_issue_success(%{"id" => "lin_task_queue_10102"})

    {:ok, _chat_task} = Pipeline.bring_local(system_scope(), issue_10102)

    {:ok, _chat_task} =
      Pipeline.update_task(system_scope(), _chat_task.id, %{
        stage: :engineer,
        stage_state: :idle,
        active_chat_role_id: role.id
      })

    assert Queue.current_live_runs_count(project, role) == 2
    assert Queue.available_slots(project, role) == 0

    # 3. Third task exceeds max_concurrent -> slots floors at 0
    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_queue_10103",
      "identifier" => "TSK-10103",
      "title" => "Task 10103"
    })

    {:ok, issue_10103} = Issues.capture_issue(system_scope(), project, "Task 10103")

    LinearMock.mock_update_issue_success(%{"id" => "lin_task_queue_10103"})

    {:ok, _another_running} = Pipeline.bring_local(system_scope(), issue_10103)

    {:ok, _another_running} =
      Pipeline.update_task(system_scope(), _another_running.id, %{
        stage: :product,
        stage_state: :running
      })

    assert Queue.current_live_runs_count(project, role) == 3
    assert Queue.available_slots(project, role) == 0
    assert [] = Queue.eligible_tasks(project, role)
  end

  test "counts rebasing tasks as live runs for the engineer role", %{project: project, task: task, roles: roles} do
    {:ok, engineer_role} =
      Roles.update_role(system_scope(), roles[:engineer], %{
        max_concurrent: 1
      })

    {:ok, product_role} =
      Roles.update_role(system_scope(), roles[:product], %{
        max_concurrent: 1
      })

    {:ok, _rebasing_task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :ready_to_merge,
        stage_state: :running,
        is_rebasing: true
      })

    assert Queue.current_live_runs_count(project, engineer_role) == 1
    assert Queue.available_slots(project, engineer_role) == 0

    # Does not count towards product role
    assert Queue.current_live_runs_count(project, product_role) == 0
    assert Queue.available_slots(project, product_role) == 1
  end

  test "returns eligible tasks ordered by inserted_at FIFO up to slot limit", %{
    project: project,
    task: task,
    roles: roles
  } do
    {:ok, role} =
      Roles.update_role(system_scope(), roles[:product], %{
        max_concurrent: 2
      })

    {:ok, %Task{id: t1_id}} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :product,
        stage_state: :queued,
        title: "First In"
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_queue_10104",
      "identifier" => "TSK-10104",
      "title" => "Second In"
    })

    {:ok, issue_10104} = Issues.capture_issue(system_scope(), project, "Second In")

    LinearMock.mock_update_issue_success(%{"id" => "lin_task_queue_10104"})

    {:ok, %Task{id: t2_id}} = Pipeline.bring_local(system_scope(), issue_10104)

    {:ok, %Task{id: t2_id}} =
      Pipeline.update_task(system_scope(), %Task{id: t2_id}.id, %{
        stage: :product,
        stage_state: :queued
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_queue_10105",
      "identifier" => "TSK-10105",
      "title" => "Third In"
    })

    {:ok, issue_10105} = Issues.capture_issue(system_scope(), project, "Third In")

    LinearMock.mock_update_issue_success(%{"id" => "lin_task_queue_10105"})

    {:ok, _t3} = Pipeline.bring_local(system_scope(), issue_10105)

    {:ok, _t3} =
      Pipeline.update_task(system_scope(), _t3.id, %{
        stage: :product,
        stage_state: :queued
      })

    # Available slots = 2, so only t1 and t2 should be returned
    assert [
             %Task{id: ^t1_id},
             %Task{id: ^t2_id}
           ] = Queue.eligible_tasks(project, role)
  end

  test "excludes tasks with retry_after in the future and includes tasks with retry_after in the past", %{
    project: project,
    task: task,
    roles: roles
  } do
    {:ok, role} =
      Roles.update_role(system_scope(), roles[:product], %{
        max_concurrent: 5
      })

    future = DateTime.shift(DateTime.utc_now(), minute: 5)
    past = DateTime.shift(DateTime.utc_now(), minute: -5)

    {:ok, _future_retry_task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :product,
        stage_state: :queued,
        retry_after: future
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_queue_10106",
      "identifier" => "TSK-10106",
      "title" => "Task 10106"
    })

    {:ok, issue_10106} = Issues.capture_issue(system_scope(), project, "Task 10106")

    LinearMock.mock_update_issue_success(%{"id" => "lin_task_queue_10106"})

    {:ok, past_retry_task} = Pipeline.bring_local(system_scope(), issue_10106)

    {:ok, past_retry_task} =
      Pipeline.update_task(system_scope(), past_retry_task.id, %{
        stage: :product,
        stage_state: :queued,
        retry_after: past
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_queue_10107",
      "identifier" => "TSK-10107",
      "title" => "Task 10107"
    })

    {:ok, issue_10107} = Issues.capture_issue(system_scope(), project, "Task 10107")

    LinearMock.mock_update_issue_success(%{"id" => "lin_task_queue_10107"})

    {:ok, nil_retry_task} = Pipeline.bring_local(system_scope(), issue_10107)

    {:ok, nil_retry_task} =
      Pipeline.update_task(system_scope(), nil_retry_task.id, %{
        stage: :product,
        stage_state: :queued,
        retry_after: nil
      })

    eligible = Queue.eligible_tasks(project.id, role)
    eligible_ids = Enum.map(eligible, & &1.id)

    assert length(eligible) == 2
    assert past_retry_task.id in eligible_ids
    assert nil_retry_task.id in eligible_ids
  end

  test "matches rebasing tasks for engineer role", %{project: project, task: task, roles: roles} do
    {:ok, engineer_role} =
      Roles.update_role(system_scope(), roles[:engineer], %{
        max_concurrent: 2
      })

    {:ok, %Task{id: rebase_task_id}} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :ready_to_merge,
        stage_state: :queued,
        is_rebasing: true
      })

    assert [%Task{id: ^rebase_task_id}] = Queue.eligible_tasks(project, engineer_role)
  end

  test "dispatches the design stage like any other", %{project: project, task: task, roles: roles} do
    {:ok, role} = Roles.update_role(system_scope(), roles[:design], %{max_concurrent: 1})

    {:ok, %Task{id: task_id}} =
      Pipeline.update_task(system_scope(), task.id, %{stage: :design, stage_state: :queued})

    assert Queue.current_live_runs_count(project, role) == 0
    assert [%Task{id: ^task_id}] = Queue.eligible_tasks(project, role)

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_queue_10109",
      "identifier" => "TSK-10109",
      "title" => "Design Running"
    })

    {:ok, issue_10109} = Issues.capture_issue(system_scope(), project, "Design Running")

    LinearMock.mock_update_issue_success(%{"id" => "lin_task_queue_10109"})

    {:ok, running_task} = Pipeline.bring_local(system_scope(), issue_10109)

    {:ok, _running_task} =
      Pipeline.update_task(system_scope(), running_task.id, %{stage: :design, stage_state: :running})

    assert Queue.current_live_runs_count(project, role) == 1
    assert Queue.available_slots(project, role) == 0
  end

  test "dispatches an off-pipeline stage like any other", %{project: project, task: task} do
    {:ok, role} =
      Roles.create_role(system_scope(), project, %{
        stage: :debugger,
        name: "debugger role",
        model: "claude-3-7-sonnet",
        system_prompt: "You are the debugger agent.",
        max_concurrent: 1
      })

    {:ok, %Task{id: task_id}} =
      Pipeline.update_task(system_scope(), task.id, %{stage: :debugger, stage_state: :queued})

    assert Queue.current_live_runs_count(project, role) == 0
    assert [%Task{id: ^task_id}] = Queue.eligible_tasks(project, role)

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_queue_10110",
      "identifier" => "TSK-10110",
      "title" => "Other Stage"
    })

    {:ok, issue_10110} = Issues.capture_issue(system_scope(), project, "Other Stage")

    LinearMock.mock_update_issue_success(%{"id" => "lin_task_queue_10110"})

    {:ok, other_stage_task} = Pipeline.bring_local(system_scope(), issue_10110)

    {:ok, _other_stage_task} =
      Pipeline.update_task(system_scope(), other_stage_task.id, %{stage: :engineer, stage_state: :queued})

    assert [%Task{id: ^task_id}] = Queue.eligible_tasks(project, role)
  end

  test "ignores tasks from other projects", %{task: task, roles: roles} do
    {:ok, project1} =
      Projects.create_project(system_scope(), %{
        name: "Queue Project 10108",
        github_repo: "org/queue-10108",
        github_installation_id: 10_108,
        linear_team_id: "team_queue_10108",
        linear_team_key: "P10108",
        clone_path: "/tmp/repos/queue-10108",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    {:ok, _project2} =
      Projects.create_project(system_scope(), %{
        name: "Queue Project 10109",
        github_repo: "org/queue-10109",
        github_installation_id: 10_109,
        linear_team_id: "team_queue_10109",
        linear_team_key: "P10109",
        clone_path: "/tmp/repos/queue-10109",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    {:ok, role1} =
      Roles.update_role(system_scope(), roles[:product], %{
        max_concurrent: 2
      })

    {:ok, _other_project_task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :product,
        stage_state: :queued
      })

    assert [] = Queue.eligible_tasks(project1, role1)
  end
end
