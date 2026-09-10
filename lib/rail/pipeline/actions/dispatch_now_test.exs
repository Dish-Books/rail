defmodule Rail.Pipeline.Actions.DispatchNowTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Roles
  alias Rail.Scope
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    scope = system_scope()

    {:ok, workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Dispatch Now Workspace",
        external_id: "lin_ws_dispatch_now",
        token: "lin_api_token_dispatch_now",
        webhook_secret: "whsec_dispatch_now"
      })

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Dispatch Now Project 9101",
        github_repo: "org/dispatch-now-9101",
        github_installation_id: 9101,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_dispatch_now_9101",
        linear_team_key: "P9101",
        clone_path: "/tmp/repos/dispatch-now-9101",
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
      "id" => "lin_dispatch_now_1",
      "identifier" => "DPN-1",
      "title" => "Dispatch Now Issue"
    })

    {:ok, issue} = Issues.capture_issue(scope, project, "Dispatch Now Issue")

    LinearMock.mock_update_issue_success(%{"id" => "lin_dispatch_now_1"})

    {:ok, task} = Pipeline.create_task(issue)

    %{project: project, issue: issue, task: task, roles: roles}
  end

  test "returns not_authorized when scope lacks permission" do
    unauth = %Scope{user: nil, system: false}
    assert {:error, :not_authorized} = Pipeline.dispatch_now(unauth, "tsk_123")
  end

  test "returns dispatch_disabled when explicitly disabled", %{task: task} do
    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :product,
        stage_state: :queued
      })

    assert {:error, :dispatch_disabled} =
             Pipeline.dispatch_now(task, dispatch_disabled: true)
  end

  test "returns dispatch_disabled when RAIL_NO_DISPATCH=1 is set in env", %{task: task} do
    Application.put_env(:rail, :no_dispatch, false)
    System.put_env("RAIL_NO_DISPATCH", "1")

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :product,
        stage_state: :queued
      })

    assert {:error, :dispatch_disabled} = Pipeline.dispatch_now(task)

    System.delete_env("RAIL_NO_DISPATCH")
    Application.put_env(:rail, :no_dispatch, true)
  end

  test "returns not_found when task identifier is invalid or does not exist" do
    opts = [dispatch_disabled: false]
    assert {:error, :not_found} = Pipeline.dispatch_now("tsk_000000000000000000000000", opts)
    assert {:error, :not_found} = Pipeline.dispatch_now(1234, opts)
    assert {:error, :not_found} = Pipeline.dispatch_now(:invalid_id, opts)
  end

  test "returns not_queued when task is not in queued stage_state", %{project: project, task: task} do
    opts = [dispatch_disabled: false]

    {:ok, running_task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :product,
        stage_state: :running
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_dispatch_now_9102",
      "identifier" => "TSK-9102",
      "title" => "Task 9102"
    })

    {:ok, issue_9102} = Issues.capture_issue(system_scope(), project, "Task 9102")

    LinearMock.mock_update_issue_success(%{"id" => "lin_task_dispatch_now_9102"})

    {:ok, failed_task} = Pipeline.create_task(issue_9102)

    {:ok, failed_task} =
      Pipeline.update_task(system_scope(), failed_task.id, %{
        stage: :product,
        stage_state: :failed
      })

    assert {:error, {:not_queued, :running}} = Pipeline.dispatch_now(running_task, opts)
    assert {:error, {:not_queued, :failed}} = Pipeline.dispatch_now(failed_task, opts)
  end

  test "returns waiting_to_retry when task retry_after is in the future", %{task: task} do
    future = DateTime.shift(DateTime.utc_now(), minute: 5)

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :product,
        stage_state: :queued,
        retry_after: future
      })

    assert {:error, :waiting_to_retry} =
             Pipeline.dispatch_now(task, dispatch_disabled: false)
  end

  test "returns project_not_found when task references nonexistent project", %{task: task} do
    {:ok, %Task{} = task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :product,
        stage_state: :queued
      })

    task_with_bad_project = %{task | project_id: "prj_000000000000000000000000"}

    assert {:error, :project_not_found} =
             Pipeline.dispatch_now(task_with_bad_project, dispatch_disabled: false)
  end

  test "returns no_role_for_stage when no role configured for stage", %{task: task, roles: roles} do
    {:ok, _deleted} = Roles.delete_role(system_scope(), roles[:design])

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :design,
        stage_state: :queued
      })

    assert {:error, {:no_role_for_stage, :design}} =
             Pipeline.dispatch_now(task, dispatch_disabled: false)
  end

  test "returns no_available_slots when role concurrency is exhausted", %{project: project, task: task, roles: roles} do
    {:ok, _role} =
      Roles.update_role(system_scope(), roles[:product], %{
        max_concurrent: 1
      })

    {:ok, _running} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :product,
        stage_state: :running
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_dispatch_now_9103",
      "identifier" => "TSK-9103",
      "title" => "Task 9103"
    })

    {:ok, issue_9103} = Issues.capture_issue(system_scope(), project, "Task 9103")

    LinearMock.mock_update_issue_success(%{"id" => "lin_task_dispatch_now_9103"})

    {:ok, task} = Pipeline.create_task(issue_9103)

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :product,
        stage_state: :queued
      })

    assert {:error, :no_available_slots} =
             Pipeline.dispatch_now(task, dispatch_disabled: false)
  end

  test "dispatches immediately when slots are available using custom dispatch hook", %{task: task, roles: roles} do
    {:ok, role} =
      Roles.update_role(system_scope(), roles[:product], %{
        max_concurrent: 2
      })

    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :product,
        stage_state: :queued
      })

    caller = self()

    hook = fn t, r ->
      send(caller, {:dispatched_hook, t.id, r.id})
      {:ok, %{t | stage_state: :running}}
    end

    opts = [dispatch_disabled: false, dispatch_hook: hook]

    assert {:ok, %Task{id: ^task_id, stage_state: :running}} =
             Pipeline.dispatch_now(task, opts)

    assert_receive {:dispatched_hook, ^task_id, r_id}
    assert r_id == role.id
  end

  test "dispatches task when retry_after has elapsed in the past", %{task: task, roles: roles} do
    {:ok, _role} =
      Roles.update_role(system_scope(), roles[:product], %{
        max_concurrent: 1
      })

    past = DateTime.shift(DateTime.utc_now(), minute: -5)

    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :product,
        stage_state: :queued,
        retry_after: past
      })

    dispatch_hook = fn hook_task, _role ->
      {:ok, dispatched} = Pipeline.update_task(system_scope(), hook_task.id, %{stage_state: :running})
      Pipeline.broadcast_pipeline_changed(%{task_id: dispatched.id, event: :dispatched})
      {:ok, dispatched}
    end

    opts = [dispatch_disabled: false, dispatch_hook: dispatch_hook]

    assert {:ok, %Task{id: ^task_id, stage_state: :running}} =
             Pipeline.dispatch_now(task, opts)
  end

  test "resolves engineer role for rebasing tasks", %{task: task, roles: roles} do
    {:ok, _role_eng} =
      Roles.update_role(system_scope(), roles[:engineer], %{
        max_concurrent: 1
      })

    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :ready_to_merge,
        stage_state: :queued,
        is_rebasing: true
      })

    dispatch_hook = fn hook_task, _role ->
      {:ok, dispatched} = Pipeline.update_task(system_scope(), hook_task.id, %{stage_state: :running})
      Pipeline.broadcast_pipeline_changed(%{task_id: dispatched.id, event: :dispatched})
      {:ok, dispatched}
    end

    opts = [dispatch_disabled: false, dispatch_hook: dispatch_hook]

    assert {:ok, %Task{id: ^task_id, stage_state: :running}} =
             Pipeline.dispatch_now(task, opts)
  end

  test "supports all arity and scope variations", %{project: project, task: task, roles: roles} do
    {:ok, _role} =
      Roles.update_role(system_scope(), roles[:product], %{
        max_concurrent: 5
      })

    {:ok, t1} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :product,
        stage_state: :queued
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_dispatch_now_9104",
      "identifier" => "TSK-9104",
      "title" => "Task 9104"
    })

    {:ok, issue_9104} = Issues.capture_issue(system_scope(), project, "Task 9104")

    LinearMock.mock_update_issue_success(%{"id" => "lin_task_dispatch_now_9104"})

    {:ok, t2} = Pipeline.create_task(issue_9104)

    {:ok, t2} =
      Pipeline.update_task(system_scope(), t2.id, %{
        stage: :product,
        stage_state: :queued
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_dispatch_now_9105",
      "identifier" => "TSK-9105",
      "title" => "Task 9105"
    })

    {:ok, issue_9105} = Issues.capture_issue(system_scope(), project, "Task 9105")

    LinearMock.mock_update_issue_success(%{"id" => "lin_task_dispatch_now_9105"})

    {:ok, t3} = Pipeline.create_task(issue_9105)

    {:ok, t3} =
      Pipeline.update_task(system_scope(), t3.id, %{
        stage: :product,
        stage_state: :queued
      })

    dispatch_hook = fn hook_task, _role ->
      {:ok, dispatched} = Pipeline.update_task(system_scope(), hook_task.id, %{stage_state: :running})
      Pipeline.broadcast_pipeline_changed(%{task_id: dispatched.id, event: :dispatched})
      {:ok, dispatched}
    end

    opts = [dispatch_disabled: false, dispatch_hook: dispatch_hook]

    # scope with opts
    sys = Scope.for_system()
    assert {:ok, %Task{stage_state: :running}} = Pipeline.dispatch_now(sys, t1, opts)

    # user scope without opts
    user_scope = %Scope{user: %{id: "usr_123"}, system: false}
    assert {:error, :dispatch_disabled} = Pipeline.dispatch_now(user_scope, t2)

    # task_or_id with opts
    assert {:ok, %Task{stage_state: :running}} = Pipeline.dispatch_now(t3.id, opts)

    # 1-arity default
    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_dispatch_now_9106",
      "identifier" => "TSK-9106",
      "title" => "Task 9106"
    })

    {:ok, issue_9106} = Issues.capture_issue(system_scope(), project, "Task 9106")

    LinearMock.mock_update_issue_success(%{"id" => "lin_task_dispatch_now_9106"})

    {:ok, t4} = Pipeline.create_task(issue_9106)

    {:ok, t4} =
      Pipeline.update_task(system_scope(), t4.id, %{
        stage: :product,
        stage_state: :queued
      })

    assert {:error, :dispatch_disabled} = Pipeline.dispatch_now(t4)
  end

  test "dispatches via default supervised runner when git repo exists", %{project: _project, task: task, roles: roles} do
    repo_dir = create_temp_git_repo()

    {:ok, _project} =
      Projects.create_project(system_scope(), %{
        name: "Dispatch Now Project 9107",
        github_repo: "org/dispatch-now-9107",
        github_installation_id: 9107,
        linear_team_id: "team_dispatch_now_9107",
        linear_team_key: "P9107",
        clone_path: repo_dir,
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        },
        default_branch: "main"
      })

    _role = roles[:product]

    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :product,
        stage_state: :queued
      })

    assert {:ok, %Task{id: ^task_id}} =
             Pipeline.dispatch_now(task, dispatch_disabled: false)
  end
end
