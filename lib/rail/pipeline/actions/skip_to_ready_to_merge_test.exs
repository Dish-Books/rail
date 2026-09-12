defmodule Rail.Pipeline.Actions.SkipToReadyToMergeTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Roles
  alias Rail.Runs
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    scope = system_scope()

    {:ok, backend} =
      Rail.Backends.create_backend(scope, %{name: :claude, executable_path: "/usr/bin/true"})

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

    {:ok, review_role} =
      Roles.create_role(scope, project, %{
        backend_id: backend.id,
        stage: :review,
        name: "review role",
        model: "claude-3-7-sonnet",
        system_prompt: "You are the reviewer."
      })

    %{project: project, issue: issue, task: task, review_role: review_role}
  end

  test "refuses to skip a gate that is still working", %{task: task, review_role: review_role} do
    {:ok, task} = Pipeline.update_task(task, %{stage: :review})

    {:ok, _running} =
      Runs.create_run(%{
        task_id: task.id,
        role_id: review_role.id,
        status: :running,
        started_at: DateTime.utc_now()
      })

    assert {:error, :stage_running} = Pipeline.skip_to_ready_to_merge(task)
  end

  test "returns invalid_stage when task is not at a gate stage", %{project: project, task: task} do
    {:ok, t_eng} =
      Pipeline.update_task(task, %{
        stage: :engineer
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
        stage: :product
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
        stage: :architect
      })

    assert {:error, {:invalid_stage, :architect}} = Pipeline.skip_to_ready_to_merge(t_arch)
  end

  test "skips to ready_to_merge awaiting_approval from review gate", %{task: task} do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")

    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(task, %{
        stage: :review,
      })

    assert {:ok,
            %Task{
              id: ^task_id,
              stage: :ready_to_merge,
            }} = Pipeline.skip_to_ready_to_merge(task)

    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :skipped_to_ready_to_merge}}
  end

  test "skips to ready_to_merge awaiting_approval from qa and qa_lead gates", %{project: project, task: task} do
    {:ok, t_qa} =
      Pipeline.update_task(task, %{
        stage: :qa
      })

    assert {:ok, %Task{stage: :ready_to_merge}} =
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
        stage: :qa_lead
      })

    assert {:ok, %Task{stage: :ready_to_merge}} =
             Pipeline.skip_to_ready_to_merge(t_lead)
  end
end
