defmodule Rail.Pipeline.Actions.SkipToReadyToMergeTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    scope = system_scope()

    {:ok, workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Skip Ready Workspace",
        external_id: "lin_ws_skip_ready",
        token: "lin_api_token_skip_ready",
        webhook_secret: "whsec_skip_ready"
      })

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Skip Ready Project 6601",
        github_repo: "org/skip-ready-6601",
        github_installation_id: 6601,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_skip_ready_6601",
        linear_team_key: "P6601",
        default_branch: "main",
        clone_path: "/tmp/repos/skip-ready-6601",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_skip_ready_1",
      "identifier" => "SKP-1",
      "title" => "Skip Ready Issue"
    })

    {:ok, issue} = Issues.capture_issue(scope, project, "Skip Ready Issue")

    {:ok, task} = Pipeline.create_task(issue, :product)

    %{project: project, issue: issue, task: task}
  end

  test "returns invalid_stage_state when task is not awaiting_approval", %{project: project, task: task} do
    {:ok, t_queued} =
      Pipeline.update_task(task, %{
        stage: :review,
        stage_state: :queued
      })

    assert {:error, {:invalid_stage_state, :queued}} = Pipeline.skip_to_ready_to_merge(t_queued)

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_skip_ready_6601",
      "identifier" => "TSK-6601",
      "title" => "Task 6601"
    })

    {:ok, issue_6601} = Issues.capture_issue(system_scope(), project, "Task 6601")

    {:ok, t_running} = Pipeline.create_task(issue_6601, :product)

    {:ok, t_running} =
      Pipeline.update_task(t_running, %{
        stage: :review,
        stage_state: :running
      })

    assert {:error, {:invalid_stage_state, :running}} = Pipeline.skip_to_ready_to_merge(t_running)
  end

  test "returns invalid_stage when task is not at a gate stage", %{project: project, task: task} do
    {:ok, t_eng} =
      Pipeline.update_task(task, %{
        stage: :engineer,
        stage_state: :awaiting_approval
      })

    assert {:error, {:invalid_stage, :engineer}} = Pipeline.skip_to_ready_to_merge(t_eng)

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_skip_ready_6602",
      "identifier" => "TSK-6602",
      "title" => "Task 6602"
    })

    {:ok, issue_6602} = Issues.capture_issue(system_scope(), project, "Task 6602")

    {:ok, t_prod} = Pipeline.create_task(issue_6602, :product)

    {:ok, t_prod} =
      Pipeline.update_task(t_prod, %{
        stage: :product,
        stage_state: :awaiting_approval
      })

    assert {:error, {:invalid_stage, :product}} = Pipeline.skip_to_ready_to_merge(t_prod)

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_skip_ready_6603",
      "identifier" => "TSK-6603",
      "title" => "Task 6603"
    })

    {:ok, issue_6603} = Issues.capture_issue(system_scope(), project, "Task 6603")

    {:ok, t_arch} = Pipeline.create_task(issue_6603, :product)

    {:ok, t_arch} =
      Pipeline.update_task(t_arch, %{
        stage: :architect,
        stage_state: :awaiting_approval
      })

    assert {:error, {:invalid_stage, :architect}} = Pipeline.skip_to_ready_to_merge(t_arch)
  end

  test "skips to ready_to_merge awaiting_approval from review gate", %{task: task} do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")

    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(task, %{
        stage: :review,
        stage_state: :awaiting_approval,
        error: "Parked on findings"
      })

    assert {:ok,
            %Task{
              id: ^task_id,
              stage: :ready_to_merge,
              stage_state: :awaiting_approval,
              error: nil
            }} = Pipeline.skip_to_ready_to_merge(task)

    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :skipped_to_ready_to_merge}}
  end

  test "skips to ready_to_merge awaiting_approval from qa and qa_lead gates", %{project: project, task: task} do
    {:ok, t_qa} =
      Pipeline.update_task(task, %{
        stage: :qa,
        stage_state: :awaiting_approval
      })

    assert {:ok, %Task{stage: :ready_to_merge, stage_state: :awaiting_approval}} =
             Pipeline.skip_to_ready_to_merge(t_qa)

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_skip_ready_6604",
      "identifier" => "TSK-6604",
      "title" => "Task 6604"
    })

    {:ok, issue_6604} = Issues.capture_issue(system_scope(), project, "Task 6604")

    {:ok, t_lead} = Pipeline.create_task(issue_6604, :product)

    {:ok, t_lead} =
      Pipeline.update_task(t_lead, %{
        stage: :qa_lead,
        stage_state: :awaiting_approval
      })

    assert {:ok, %Task{stage: :ready_to_merge, stage_state: :awaiting_approval}} =
             Pipeline.skip_to_ready_to_merge(t_lead)
  end
end
