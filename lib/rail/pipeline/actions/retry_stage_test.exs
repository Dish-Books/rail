defmodule Rail.Pipeline.Actions.RetryStageTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Runs
  alias Rail.Runs.Schemas.Run
  alias Rail.Scope
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    {:ok, backend} =
      Rail.Backends.create_backend(system_scope(), %{name: :claude, executable_path: "/usr/bin/true"})

    scope = system_scope()

    {:ok, workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Retry Stage Workspace",
        external_id: "lin_ws_retry_stage",
        token: "lin_api_token_retry_stage",
        webhook_secret: "whsec_retry_stage"
      })

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Retry Stage Project 8001",
        github_repo: "org/retry-stage-8001",
        github_installation_id: 8001,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_retry_stage_8001",
        linear_team_key: "P8001",
        default_branch: "main",
        clone_path: "/tmp/repos/retry-stage-8001",
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
      "id" => "lin_retry_stage_1",
      "identifier" => "RTS-1",
      "title" => "Retry Stage Issue"
    })

    {:ok, issue} = Issues.capture_issue(scope, project, "Retry Stage Issue")

    {:ok, task} = Pipeline.create_task(issue, :product)

    %{project: project, issue: issue, task: task, roles: roles}
  end

  test "returns not_found when task cannot be resolved" do
    assert {:error, :not_found} = Pipeline.retry_stage("tsk_000000000000000000000000")
  end

  test "returns not_authorized when scope lacks permission", %{task: task} do
    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :engineer,
        stage_state: :failed
      })

    unauth_scope = %Scope{user: nil, system: false}

    assert {:error, :not_authorized} = Pipeline.retry_stage(unauth_scope, task.id)
  end

  test "returns role_not_found when stage lacks a configured role", %{task: task, roles: roles} do
    {:ok, _deleted} = Roles.delete_role(system_scope(), roles[:engineer])

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :engineer,
        stage_state: :failed
      })

    assert {:error, :role_not_found} = Pipeline.retry_stage(task)
  end

  test "clears retry_after and error, sets stage_state to queued, and resets auto_retries", %{task: task, roles: roles} do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")

    {:ok, role_eng} =
      Roles.update_role(system_scope(), roles[:engineer], %{
        name: "Engineer"
      })

    retry_time = DateTime.shift(DateTime.utc_now(), minute: 1)

    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :engineer,
        stage_state: :failed,
        retry_after: retry_time,
        error: "Transient socket hang up"
      })

    {:ok, _run} =
      Runs.create_run(%{
        task_id: task_id,
        role_id: role_eng.id,
        status: :finished,
        started_at: DateTime.utc_now(),
        auto_retries: 2
      })

    assert {:ok,
            %Task{
              id: ^task_id,
              stage_state: :queued,
              retry_after: nil,
              error: nil
            }} = Pipeline.retry_stage(task)

    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :stage_retried}}

    eng_run = Repo.one(from r in Run, where: r.task_id == ^task_id and r.role_id == ^role_eng.id)
    assert eng_run.auto_retries == 0
  end

  test "resolves engineer role when task is rebasing", %{task: task, roles: roles} do
    {:ok, role_eng} =
      Roles.update_role(system_scope(), roles[:engineer], %{
        name: "Engineer"
      })

    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :ready_to_merge,
        stage_state: :failed,
        is_rebasing: true,
        error: "Merge conflict"
      })

    {:ok, _run} =
      Runs.create_run(%{
        task_id: task_id,
        role_id: role_eng.id,
        status: :finished,
        started_at: DateTime.utc_now(),
        auto_retries: 1
      })

    assert {:ok, %Task{id: ^task_id, stage_state: :queued, error: nil}} =
             Pipeline.retry_stage(task)

    eng_run = Repo.one(from r in Run, where: r.task_id == ^task_id and r.role_id == ^role_eng.id)
    assert eng_run.auto_retries == 0
  end

  test "handles retry when run row does not exist yet", %{task: task, roles: roles} do
    _role = roles[:product]

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :product,
        stage_state: :failed,
        error: "Initial startup error"
      })

    assert {:ok, %Task{stage_state: :queued, error: nil}} =
             Pipeline.retry_stage(task)
  end

  test "supports scope-based invocation with task id", %{task: task, roles: roles} do
    _role = roles[:product]

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :product,
        stage_state: :failed
      })

    scope = Scope.for_system()
    assert {:ok, %Task{stage_state: :queued}} = Pipeline.retry_stage(scope, task.id)
  end

  test "authorizes scope with user and handles invalid task argument", %{task: task, roles: roles} do
    _role = roles[:product]

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :product,
        stage_state: :failed
      })

    user_scope = %Scope{user: %{id: "usr_test"}, system: false}

    assert {:ok, %Task{stage_state: :queued}} = Pipeline.retry_stage(user_scope, task.id)
    assert {:error, :not_found} = Pipeline.retry_stage(user_scope, :invalid_task)
  end
end
