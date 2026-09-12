defmodule Rail.Pipeline.Actions.SettleRebaseRunTest do
  use Rail.DataCase, async: true

  import RailTest.Mocks.GitHub

  alias Rail.Issues
  alias Rail.Pipeline
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
        name: "Settle Rebase Workspace",
        external_id: "lin_ws_settle_rebase",
        token: "lin_api_token_settle_rebase",
        webhook_secret: "whsec_settle_rebase"
      })

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Settle Rebase Project 14609",
        github_repo: "org/settle-rebase-14609",
        github_installation_id: 14_609,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_settle_rebase_14609",
        linear_team_key: "P14609",
        default_branch: "main",
        clone_path: "/tmp/repos/settle-rebase-14609",
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
      "id" => "lin_settle_rebase_1",
      "identifier" => "S14609-1",
      "title" => "Settle Rebase Issue"
    })

    {:ok, issue} = Issues.capture_issue(scope, project, "Settle Rebase Issue")

    {:ok, task} = Pipeline.create_task(issue, :product)

    # These tests exercise stage transitions, not Linear publishing.
    {:ok, task} = Pipeline.update_task(scope, task.id, %{issue_id: nil})

    %{backend: backend, project: project, issue: issue, task: task, roles: roles}
  end

  test "settles clean exit 0 for rebasing task restoring previous stage state", %{task: task, roles: roles} do
    {:ok, %Task{id: task_id} = _task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :ready_to_merge,
        stage_state: :running,
        is_rebasing: true,
        stage_state_before_rebase: :awaiting_approval
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
        stream_path: "/tmp/settle_rebase/#{run.id}.ndjson",
        node: to_string(Node.self()),
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    {:ok, _settled_task, _settled_run} = Pipeline.settle_run(os_process, %{exit_code: 0})

    assert {:ok,
            %Task{
              id: ^task_id,
              is_rebasing: false,
              stage_state: :awaiting_approval,
              stage_state_before_rebase: nil
            }, %Run{status: :finished, exit_code: 0, auto_retries: 0}} =
             Pipeline.settle_rebase_run(os_process)
  end

  test "settling clean exit 0 for rebasing task restores previous state and refreshes mergeability", %{
    project: project,
    task: task,
    roles: roles
  } do
    {:ok, _project} = Projects.update_project(system_scope(), project, %{github_repo: "testorg/rebase_settle"})

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :review,
        stage_state: :running,
        is_rebasing: true,
        stage_state_before_rebase: :awaiting_approval,
        pr_number: 999,
        mergeability: :conflicting,
        pr_is_draft: false
      })

    {:ok, run} =
      Runs.create_run(%{
        task_id: task.id,
        role_id: roles[:engineer].id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    mock_pull_request_state_success("testorg/rebase_settle", 999, mergeable: true, draft: false)

    os_process =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: run.task_id,
        stream_path: "/tmp/settle_rebase/#{run.id}.ndjson",
        node: to_string(Node.self()),
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    {:ok, _settled_task, _settled_run} = Pipeline.settle_run(os_process, %{exit_code: 0})

    assert {:ok,
            %Task{
              is_rebasing: false,
              stage_state: :awaiting_approval,
              stage_state_before_rebase: nil,
              mergeability: :mergeable
            }, %Run{status: :finished}} =
             Pipeline.settle_rebase_run(os_process, %{}, token: "tok_test")
  end

  test "settling non-zero exit for rebasing task preserves is_rebasing for retries", %{task: task, roles: roles} do
    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :review,
        stage_state: :running,
        is_rebasing: true,
        stage_state_before_rebase: :queued
      })

    {:ok, run} =
      Runs.create_run(%{
        task_id: task.id,
        role_id: roles[:engineer].id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now(),
        auto_retries: 0
      })

    os_process =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: run.task_id,
        stream_path: "/tmp/settle_rebase/#{run.id}.ndjson",
        node: to_string(Node.self()),
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    {:ok, _settled_task, _settled_run} = Pipeline.settle_run(os_process, %{exit_code: 1, error: "Permanent error"})

    assert {:ok,
            %Task{
              is_rebasing: true,
              stage_state: :failed,
              error: "Permanent error"
            }, %Run{status: :finished}} =
             Pipeline.settle_rebase_run(os_process)
  end

  test "settling clean exit for rebasing task falls back to updated_task if refresh_mergeability fails", %{
    project: project,
    task: task,
    roles: roles
  } do
    {:ok, _project} = Projects.update_project(system_scope(), project, %{github_repo: "testorg/rebase_settle_fail"})

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :ready_to_merge,
        stage_state: :running,
        is_rebasing: true,
        stage_state_before_rebase: :awaiting_approval,
        mergeability: :unknown,
        pr_number: 998,
        pr_is_draft: false
      })

    {:ok, run} =
      Runs.create_run(%{
        task_id: task.id,
        role_id: roles[:engineer].id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    mock_pull_request_state_error("testorg/rebase_settle_fail", 998, 500, "Internal Server Error")

    os_process =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: run.task_id,
        stream_path: "/tmp/settle_rebase/#{run.id}.ndjson",
        node: to_string(Node.self()),
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    {:ok, _settled_task, _settled_run} = Pipeline.settle_run(os_process, %{exit_code: 0})

    assert {:ok,
            %Task{
              is_rebasing: false,
              stage_state: :awaiting_approval,
              stage_state_before_rebase: nil,
              mergeability: :unknown
            }, %Run{status: :finished}} =
             Pipeline.settle_rebase_run(os_process, %{}, token: "tok_test")
  end
end
