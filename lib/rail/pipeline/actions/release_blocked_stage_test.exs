defmodule Rail.Pipeline.Actions.ReleaseBlockedStageTest do
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
    scope = system_scope()

    {:ok, workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Release Blocked Workspace",
        external_id: "lin_ws_release_blocked",
        token: "lin_api_token_release_blocked",
        webhook_secret: "whsec_release_blocked"
      })

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Release Blocked Project 6801",
        github_repo: "org/release-blocked-6801",
        github_installation_id: 6801,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_release_blocked_6801",
        linear_team_key: "P6801",
        default_branch: "main",
        clone_path: "/tmp/repos/release-blocked-6801",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_release_blocked_1",
      "identifier" => "RBS-1",
      "title" => "Release Blocked Issue"
    })

    {:ok, issue} = Issues.capture_issue(scope, project, "Release Blocked Issue")

    {:ok, task} = Pipeline.create_task(issue, :product)

    %{project: project, issue: issue, task: task}
  end

  test "releases to running state when active process is running", %{project: _project, task: task} do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Release Blocked Project 6802",
        github_repo: "org/release-blocked-6802",
        github_installation_id: 6802,
        linear_team_id: "team_release_blocked_6802",
        linear_team_key: "P6802",
        default_branch: "main",
        clone_path: "/tmp/repos/release-blocked-6802",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    {:ok, role} =
      Roles.create_role(system_scope(), project, %{
        name: "Role 6806",
        model: "claude-3-7-sonnet",
        system_prompt: "You are an expert agent for role 6806.",
        stage: :engineer
      })

    {:ok, q} =
      Pipeline.register_question(task, %{
        prompt: "Question prompt 6812?",
        status: :pending
      })

    {:ok, %Task{id: task_id}} =
      Pipeline.update_task(system_scope(), task, %{
        stage: :engineer,
        stage_state: :blocked,
        question_id: q.id
      })

    {:ok, role_run} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: role.id,
        status: :blocked_on_input,
        started_at: DateTime.utc_now()
      })

    _run =
      Repo.insert!(%Run{
        role_run_id: role_run.id,
        task_id: task_id,
        kind: :stage,
        status: :running,
        stream_path: "/tmp/fake_stream",
        node: "node_test",
        started_at: DateTime.utc_now()
      })

    assert {:ok, %Task{stage_state: :running, question_id: nil}} =
             Pipeline.release_blocked_stage(task_id)

    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :stage_released}}
  end

  test "resumes stage settlement and advances stage when finished run had exit_code 0", %{project: _project, task: task} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Release Blocked Project 6803",
        github_repo: "org/release-blocked-6803",
        github_installation_id: 6803,
        linear_team_id: "team_release_blocked_6803",
        linear_team_key: "P6803",
        default_branch: "main",
        clone_path: "/tmp/repos/release-blocked-6803",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    {:ok, role} =
      Roles.create_role(system_scope(), project, %{
        name: "Role 6807",
        model: "claude-3-7-sonnet",
        system_prompt: "You are an expert agent for role 6807.",
        stage: :engineer
      })

    {:ok, q} =
      Pipeline.register_question(task, %{
        prompt: "Question prompt 6813?",
        status: :pending
      })

    {:ok, task} =
      Pipeline.update_task(system_scope(), task, %{
        stage: :engineer,
        stage_state: :blocked,
        question_id: q.id
      })

    {:ok, role_run} =
      Runs.create_role_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :blocked_on_input,
        started_at: DateTime.utc_now(),
        exit_code: 0
      })

    _run =
      Repo.insert!(%Run{
        role_run_id: role_run.id,
        task_id: task.id,
        kind: :stage,
        status: :finished,
        stream_path: "/tmp/fake_stream_0",
        node: "node_test",
        started_at: DateTime.utc_now()
      })

    assert {:ok, %Task{stage: :review, stage_state: :queued, question_id: nil}} =
             Pipeline.release_blocked_stage(task)
  end

  test "sets failed state when finished run had non-zero exit_code", %{project: _project, task: task} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Release Blocked Project 6804",
        github_repo: "org/release-blocked-6804",
        github_installation_id: 6804,
        linear_team_id: "team_release_blocked_6804",
        linear_team_key: "P6804",
        default_branch: "main",
        clone_path: "/tmp/repos/release-blocked-6804",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    {:ok, role} =
      Roles.create_role(system_scope(), project, %{
        name: "Role 6808",
        model: "claude-3-7-sonnet",
        system_prompt: "You are an expert agent for role 6808.",
        stage: :engineer
      })

    {:ok, q} =
      Pipeline.register_question(task, %{
        prompt: "Question prompt 6814?",
        status: :pending
      })

    {:ok, task} =
      Pipeline.update_task(system_scope(), task, %{
        stage: :engineer,
        stage_state: :blocked,
        question_id: q.id
      })

    {:ok, role_run} =
      Runs.create_role_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :blocked_on_input,
        started_at: DateTime.utc_now(),
        exit_code: 1
      })

    _run =
      Repo.insert!(%Run{
        role_run_id: role_run.id,
        task_id: task.id,
        kind: :stage,
        status: :finished,
        stream_path: "/tmp/fake_stream_err",
        node: "node_test",
        started_at: DateTime.utc_now()
      })

    assert {:ok, %Task{stage_state: :failed, question_id: nil}} =
             Pipeline.release_blocked_stage(task)
  end

  test "falls back to awaiting_approval when no run is behind the task", %{project: _project, task: task} do
    {:ok, _project} =
      Projects.create_project(system_scope(), %{
        name: "Release Blocked Project 6805",
        github_repo: "org/release-blocked-6805",
        github_installation_id: 6805,
        linear_team_id: "team_release_blocked_6805",
        linear_team_key: "P6805",
        default_branch: "main",
        clone_path: "/tmp/repos/release-blocked-6805",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    {:ok, q} =
      Pipeline.register_question(task, %{
        prompt: "Question prompt 6815?",
        status: :pending
      })

    {:ok, task} =
      Pipeline.update_task(system_scope(), task, %{
        stage_state: :blocked,
        question_id: q.id
      })

    assert {:ok, %Task{stage_state: :awaiting_approval, question_id: nil}} =
             Pipeline.release_blocked_stage(task)
  end

  test "validates scope authorization and task existence", %{task: task} do
    assert {:error, :not_authorized} = Pipeline.release_blocked_stage(%Rail.Scope{}, "tsk_any")
    assert {:error, :not_found} = Pipeline.release_blocked_stage("tsk_missing")
    assert {:error, :not_found} = Pipeline.release_blocked_stage(123)

    {:ok, task} =
      Pipeline.update_task(system_scope(), task, %{
        stage_state: :blocked
      })

    user_scope = %Rail.Scope{user: %{id: "usr_test"}}
    assert {:ok, %Task{stage_state: :awaiting_approval}} = Pipeline.release_blocked_stage(user_scope, task.id)
  end
end
