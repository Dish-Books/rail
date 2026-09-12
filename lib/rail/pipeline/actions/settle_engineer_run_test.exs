defmodule Rail.Pipeline.Actions.SettleEngineerRunTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Runs
  alias Rail.Runs.Schemas.OsProcess
  alias Rail.Runs.Schemas.Run
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    {:ok, backend} =
      Rail.Backends.create_backend(system_scope(), %{name: :claude, executable_path: "/usr/bin/true"})

    scope = system_scope()

    {:ok, workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Settle Engineer Workspace",
        external_id: "lin_ws_settle_engineer",
        token: "lin_api_token_settle_engineer",
        webhook_secret: "whsec_settle_engineer"
      })

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Settle Engineer Project 14604",
        github_repo: "org/settle-engineer-14604",
        github_installation_id: 14_604,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_settle_engineer_14604",
        linear_team_key: "P14604",
        default_branch: "main",
        clone_path: "/tmp/repos/settle-engineer-14604",
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
      "id" => "lin_settle_engineer_1",
      "identifier" => "S14604-1",
      "title" => "Settle Engineer Issue"
    })

    {:ok, issue} = Issues.capture_issue(scope, project, "Settle Engineer Issue")

    {:ok, task} = Pipeline.create_task(issue, :product)

    # These tests exercise stage transitions, not Linear publishing.
    {:ok, task} = Pipeline.update_task(scope, task.id, %{issue_id: nil})

    %{backend: backend, project: project, issue: issue, task: task, roles: roles}
  end

  test "settles clean exit 0 for engineer stage advancing to review", %{task: task, roles: roles} do
    {:ok, %Task{id: task_id} = _task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :engineer,
        stage_state: :running
      })

    {:ok, run} =
      Runs.create_run(%{
        task_id: task_id,
        role_id: roles[:engineer].id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    os_process =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: run.task_id,
        stream_path: "/tmp/settle_engineer/#{run.id}.ndjson",
        node: to_string(Node.self()),
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    {:ok, _settled_task, _settled_run} = Pipeline.settle_run(os_process, %{exit_code: 0})

    assert {:ok, %Task{id: ^task_id, stage: :review, stage_state: :queued}, %Run{status: :finished, exit_code: 0}} =
             Pipeline.settle_engineer_run(os_process)
  end

  test "handles transient failure with retry backoff when auto retries remain", %{task: task, roles: roles} do
    {:ok, %Task{id: task_id} = _task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :engineer,
        stage_state: :running
      })

    {:ok, run} =
      Runs.create_run(%{
        task_id: task_id,
        role_id: roles[:engineer].id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now(),
        auto_retries: 0
      })

    transient_err = "rate limit exceeded: 429 too many requests"

    os_process =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: run.task_id,
        stream_path: "/tmp/settle_engineer/#{run.id}.ndjson",
        node: to_string(Node.self()),
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    {:ok, _settled_task, _settled_run} = Pipeline.settle_run(os_process, %{exit_code: 1, error: transient_err})

    assert {:ok,
            %Task{
              id: ^task_id,
              stage_state: :queued,
              retry_after: %DateTime{},
              error: ^transient_err
            }, %Run{status: :finished, auto_retries: 1, exit_code: 1}} =
             Pipeline.settle_engineer_run(os_process)
  end

  test "handles transient failure marking failed when max auto retries are exhausted", %{task: task, roles: roles} do
    {:ok, %Task{id: task_id} = _task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :engineer,
        stage_state: :running
      })

    {:ok, run} =
      Runs.create_run(%{
        task_id: task_id,
        role_id: roles[:engineer].id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now(),
        auto_retries: 2
      })

    transient_err = "rate limit exceeded: 429 too many requests"

    os_process =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: run.task_id,
        stream_path: "/tmp/settle_engineer/#{run.id}.ndjson",
        node: to_string(Node.self()),
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    {:ok, _settled_task, _settled_run} = Pipeline.settle_run(os_process, %{exit_code: 1, error: transient_err})

    assert {:ok, %Task{id: ^task_id, stage_state: :failed, retry_after: nil, error: ^transient_err},
            %Run{status: :finished, auto_retries: 2, exit_code: 1}} =
             Pipeline.settle_engineer_run(os_process)
  end

  test "handles permanent failure immediately marking task and run as failed", %{task: task, roles: roles} do
    {:ok, %Task{id: task_id} = _task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :engineer,
        stage_state: :running
      })

    {:ok, run} =
      Runs.create_run(%{
        task_id: task_id,
        role_id: roles[:engineer].id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now(),
        auto_retries: 0
      })

    perm_err = "fatal syntax error: unexpected token"

    os_process =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: run.task_id,
        stream_path: "/tmp/settle_engineer/#{run.id}.ndjson",
        node: to_string(Node.self()),
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    {:ok, _settled_task, _settled_run} = Pipeline.settle_run(os_process, %{exit_code: 1, error: perm_err})

    assert {:ok, %Task{id: ^task_id, stage_state: :failed, error: ^perm_err},
            %Run{status: :finished, auto_retries: 0, exit_code: 1}} =
             Pipeline.settle_engineer_run(os_process)
  end

  test "settle_run preserves blocked state when task was already blocked on question", %{task: task, roles: roles} do
    role = roles[:engineer]

    {:ok, %Question{id: expected_q_id}} =
      Pipeline.register_question(task, %{
        prompt: "Question prompt 14599?"
      })

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :engineer,
        stage_state: :blocked,
        question_id: expected_q_id
      })

    {:ok, run} =
      Runs.create_run(%{
        task_id: task.id,
        role_id: role.id,
        conversation_id: "sess_fixture",
        status: :blocked_on_input,
        started_at: DateTime.utc_now()
      })

    Runs.append_run_event(run, "Exiting after ask")

    os_process =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: run.task_id,
        stream_path: "/tmp/settle_engineer/#{run.id}.ndjson",
        node: to_string(Node.self()),
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    {:ok, _settled_task, _settled_run} = Pipeline.settle_run(os_process, %{exit_code: 0})

    assert {:ok, %Task{stage: :engineer, stage_state: :blocked, question_id: ^expected_q_id},
            %Run{status: :blocked_on_input, exit_code: 0}} =
             Pipeline.settle_engineer_run(os_process)
  end
end
