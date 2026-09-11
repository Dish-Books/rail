defmodule Rail.Pipeline.TaskActionRunnerTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Pipeline.TaskActionRunner
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Roles
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    scope = system_scope()

    {:ok, workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Task Runner Workspace",
        external_id: "lin_ws_task_runner",
        token: "lin_api_token_task_runner",
        webhook_secret: "whsec_task_runner"
      })

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Task Runner Project 10301",
        github_repo: "org/task-runner-10301",
        github_installation_id: 10_301,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_task_runner_10301",
        linear_team_key: "P10301",
        default_branch: "main",
        clone_path: "/tmp/repos/task-runner-10301",
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
      "id" => "lin_task_runner_1",
      "identifier" => "TAR-1",
      "title" => "Task Runner Issue"
    })

    {:ok, issue} = Issues.capture_issue(scope, project, "Task Runner Issue")

    {:ok, task} = Pipeline.create_task(issue, :product)

    %{project: project, issue: issue, task: task, roles: roles}
  end

  test "tracks running action, clears error on start, enforces single-flight, and finishes", %{
    project: _project,
    task: _task
  } do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Task Runner Project 10302",
        github_repo: "org/task-runner-10302",
        github_installation_id: 10_302,
        linear_team_id: "team_task_runner_10302",
        linear_team_key: "P10302",
        default_branch: "main",
        clone_path: "/tmp/repos/task-runner-10302",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_task_runner_10303",
      "identifier" => "TSK-10303",
      "title" => "Task 10303"
    })

    {:ok, issue_10303} = Issues.capture_issue(system_scope(), project, "Task 10303")

    {:ok, %Task{id: task_id}} = Pipeline.create_task(issue_10303, :product)

    {:ok, %Task{id: task_id}} =
      Pipeline.update_task(system_scope(), %Task{id: task_id}.id, %{
        error: "Existing error to be cleared"
      })

    refute TaskActionRunner.is_busy?(task_id)
    assert TaskActionRunner.running_on(task_id) == nil

    # Start action
    assert :ok = TaskActionRunner.start_action(task_id, :merge)
    assert TaskActionRunner.is_busy?(task_id)
    assert TaskActionRunner.running_on(task_id) == :merge

    # Asserts that start_action immediately cleared old error
    assert %Task{error: nil} = Repo.get!(Task, task_id)
    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :action_started, kind: :merge}}

    # Single-flight: second start attempts return {:error, :busy}
    assert {:error, :busy} = TaskActionRunner.start_action(task_id, :merge)
    assert {:error, :busy} = TaskActionRunner.start_action(task_id, :rebase)

    # Finish action
    assert :ok = TaskActionRunner.finish_action(task_id, :merge, {:ok, :done})
    refute TaskActionRunner.is_busy?(task_id)
    assert TaskActionRunner.running_on(task_id) == nil
    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :action_finished, kind: :merge}}
  end

  test "finish_action with error or timeout writes error message to task", %{project: _project, task: _task} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Task Runner Project 10304",
        github_repo: "org/task-runner-10304",
        github_installation_id: 10_304,
        linear_team_id: "team_task_runner_10304",
        linear_team_key: "P10304",
        default_branch: "main",
        clone_path: "/tmp/repos/task-runner-10304",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_task_runner_10305",
      "identifier" => "TSK-10305",
      "title" => "Task 10305"
    })

    {:ok, issue_10305} = Issues.capture_issue(system_scope(), project, "Task 10305")

    {:ok, %Task{id: task_id}} = Pipeline.create_task(issue_10305, :product)

    {:ok, %Task{id: task_id}} =
      Pipeline.update_task(system_scope(), %Task{id: task_id}.id, %{
        error: nil
      })

    # Finish with standard error
    assert :ok = TaskActionRunner.start_action(task_id, :rebase)
    assert :ok = TaskActionRunner.finish_action(task_id, :rebase, {:error, "Rebase conflict failed"})
    assert %Task{error: "Rebase conflict failed"} = Repo.get!(Task, task_id)

    # Finish with timeout
    assert :ok = TaskActionRunner.start_action(task_id, :merge)
    assert :ok = TaskActionRunner.finish_action(task_id, :merge, {:error, :timeout})
    assert %Task{error: "Action merge timed out"} = Repo.get!(Task, task_id)
  end

  test "forget/2 releases lock without writing error", %{project: _project, task: _task} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Task Runner Project 10306",
        github_repo: "org/task-runner-10306",
        github_installation_id: 10_306,
        linear_team_id: "team_task_runner_10306",
        linear_team_key: "P10306",
        default_branch: "main",
        clone_path: "/tmp/repos/task-runner-10306",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_task_runner_10307",
      "identifier" => "TSK-10307",
      "title" => "Task 10307"
    })

    {:ok, issue_10307} = Issues.capture_issue(system_scope(), project, "Task 10307")

    {:ok, %Task{id: task_id}} = Pipeline.create_task(issue_10307, :product)

    {:ok, %Task{id: task_id}} =
      Pipeline.update_task(system_scope(), %Task{id: task_id}.id, %{
        error: nil
      })

    assert :ok = TaskActionRunner.start_action(task_id, :cleanup)
    assert TaskActionRunner.is_busy?(task_id)

    assert :ok = TaskActionRunner.forget(task_id)
    refute TaskActionRunner.is_busy?(task_id)
    assert %Task{error: nil} = Repo.get!(Task, task_id)
  end

  test "run/5 executes work single-flight and cleans up lock", %{project: _project, task: _task} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Task Runner Project 10308",
        github_repo: "org/task-runner-10308",
        github_installation_id: 10_308,
        linear_team_id: "team_task_runner_10308",
        linear_team_key: "P10308",
        default_branch: "main",
        clone_path: "/tmp/repos/task-runner-10308",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_task_runner_10309",
      "identifier" => "TSK-10309",
      "title" => "Task 10309"
    })

    {:ok, issue_10309} = Issues.capture_issue(system_scope(), project, "Task 10309")

    {:ok, %Task{id: task_id}} = Pipeline.create_task(issue_10309, :product)

    {:ok, %Task{id: task_id}} =
      Pipeline.update_task(system_scope(), %Task{id: task_id}.id, %{
        error: nil
      })

    assert {:ok, :success} =
             TaskActionRunner.run(task_id, :approve, fn ->
               {:ok, :success}
             end)

    refute TaskActionRunner.is_busy?(task_id)
  end

  test "run/5 enforces single-flight and rejects re-entry", %{project: _project, task: _task} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Task Runner Project 10310",
        github_repo: "org/task-runner-10310",
        github_installation_id: 10_310,
        linear_team_id: "team_task_runner_10310",
        linear_team_key: "P10310",
        default_branch: "main",
        clone_path: "/tmp/repos/task-runner-10310",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_task_runner_10311",
      "identifier" => "TSK-10311",
      "title" => "Task 10311"
    })

    {:ok, issue_10311} = Issues.capture_issue(system_scope(), project, "Task 10311")

    {:ok, %Task{id: task_id}} = Pipeline.create_task(issue_10311, :product)

    {:ok, %Task{id: task_id}} =
      Pipeline.update_task(system_scope(), %Task{id: task_id}.id, %{
        error: nil
      })

    assert :ok = TaskActionRunner.start_action(task_id, :cleanup)

    assert {:error, :busy} =
             TaskActionRunner.run(task_id, :cleanup, fn ->
               {:ok, :should_not_run}
             end)

    TaskActionRunner.forget(task_id)
  end

  test "run/5 handles timeout and failure", %{project: _project, task: _task} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Task Runner Project 10312",
        github_repo: "org/task-runner-10312",
        github_installation_id: 10_312,
        linear_team_id: "team_task_runner_10312",
        linear_team_key: "P10312",
        default_branch: "main",
        clone_path: "/tmp/repos/task-runner-10312",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_task_runner_10313",
      "identifier" => "TSK-10313",
      "title" => "Task 10313"
    })

    {:ok, issue_10313} = Issues.capture_issue(system_scope(), project, "Task 10313")

    {:ok, %Task{id: task_id}} = Pipeline.create_task(issue_10313, :product)

    {:ok, %Task{id: task_id}} =
      Pipeline.update_task(system_scope(), %Task{id: task_id}.id, %{
        error: nil
      })

    # Timeout
    assert {:error, :timeout} =
             TaskActionRunner.run(
               task_id,
               :merge,
               fn ->
                 Process.sleep(100)
                 {:ok, :slow}
               end,
               timeout: 10
             )

    assert %Task{error: "Action merge timed out"} = Repo.get!(Task, task_id)
    refute TaskActionRunner.is_busy?(task_id)

    # Failure
    assert {:error, "Network error"} =
             TaskActionRunner.run(task_id, :recheck_design, fn ->
               {:error, "Network error"}
             end)

    assert %Task{error: "Network error"} = Repo.get!(Task, task_id)
    refute TaskActionRunner.is_busy?(task_id)

    # Bare result (not wrapped in {:ok, _} or {:error, _})
    assert {:ok, :bare_result} =
             TaskActionRunner.run(task_id, :rebase, fn ->
               :bare_result
             end)

    # Process exit / crash
    Process.flag(:trap_exit, true)

    assert {:error, :crashed} =
             TaskActionRunner.run(task_id, :rebase, fn ->
               exit(:crashed)
             end)

    # Run on non-existent task_id exercises clear_task_error and set_task_error nil branches
    assert {:error, "failed"} =
             TaskActionRunner.run("tsk_nonexistent_999", :rebase, fn ->
               {:error, "failed"}
             end)
  end

  test "shows_progress? returns true only for merge, cleanup, mark_ready, and recheck_design" do
    assert TaskActionRunner.shows_progress?(:merge)
    assert TaskActionRunner.shows_progress?(:cleanup)
    assert TaskActionRunner.shows_progress?(:mark_ready)
    assert TaskActionRunner.shows_progress?(:recheck_design)

    refute TaskActionRunner.shows_progress?(:rebase)
    refute TaskActionRunner.shows_progress?(:comment)
    refute TaskActionRunner.shows_progress?(:approve)
    refute TaskActionRunner.shows_progress?(:send_back)
    refute TaskActionRunner.shows_progress?(:retry)
    refute TaskActionRunner.shows_progress?(:dispatch)
    refute TaskActionRunner.shows_progress?(:cancel)
    refute TaskActionRunner.shows_progress?(:other)
    refute TaskActionRunner.shows_progress?("non-atom")
    refute TaskActionRunner.shows_progress?(nil)
  end

  test "timeout_for returns expected defaults or overrides" do
    assert TaskActionRunner.timeout_for(:merge) == 180_000
    assert TaskActionRunner.timeout_for(:cleanup) == 120_000
    assert TaskActionRunner.timeout_for(:mark_ready) == 60_000
    assert TaskActionRunner.timeout_for(:recheck_design) == 60_000
    assert TaskActionRunner.timeout_for(:rebase) == 60_000
    assert TaskActionRunner.timeout_for(:approve) == 60_000

    assert TaskActionRunner.timeout_for(:merge, timeout: 5_000) == 5_000
  end
end
