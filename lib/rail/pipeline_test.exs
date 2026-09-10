defmodule Rail.PipelineTest do
  use Rail.DataCase, async: true

  import RailTest.PipelineHelpers

  alias Rail.Artifacts
  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Roles
  alias Rail.Runs
  alias Rail.Scope
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    scope = system_scope()

    {:ok, workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Pipeline Context Workspace",
        external_id: "lin_ws_pipeline_context",
        token: "lin_api_token_pipeline_context",
        webhook_secret: "whsec_pipeline_context"
      })

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Pipeline Context Project 10201",
        github_repo: "org/pipeline-context-10201",
        github_installation_id: 10_201,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_pipeline_context_10201",
        linear_team_key: "P10201",
        clone_path: "/tmp/repos/pipeline-context-10201",
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
      "id" => "lin_pipeline_context_1",
      "identifier" => "PLC-1",
      "title" => "Pipeline Context Issue"
    })

    {:ok, issue} = Issues.capture_issue(scope, project, "Pipeline Context Issue")

    LinearMock.mock_update_issue_success(%{"id" => "lin_pipeline_context_1"})

    {:ok, task} = Pipeline.bring_local(scope, issue)

    %{project: project, issue: issue, task: task, roles: roles}
  end

  test "delegates get_task and get_task!", %{task: task} do
    scope = Scope.for_system()
    %Task{id: task_id} = task

    assert {:ok, %Task{id: ^task_id}} = Pipeline.get_task(scope, task_id)
    assert %Task{id: ^task_id} = Pipeline.get_task!(scope, task_id)
  end

  test "delegates list_tasks", %{project: project, task: task} do
    %Task{id: task_id} = task
    scope = Scope.for_system()

    assert [%Task{id: ^task_id}] = Pipeline.list_tasks(scope, project.id)
  end

  test "delegates broadcast_pipeline_changed" do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")

    assert :ok = Pipeline.broadcast_pipeline_changed(%{test: true})
    assert_receive {:pipeline_changed, %{test: true}}
  end

  test "delegates list_eligible_tasks", %{project: project, task: task, roles: roles} do
    role = roles[:product]

    {:ok, %Task{id: task_id}} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :product,
        stage_state: :queued
      })

    assert [%Task{id: ^task_id}] = Pipeline.list_eligible_tasks(project, role)
  end

  test "delegates dispatcher controls" do
    assert Pipeline.dispatch_disabled?() == true
    assert match?({:disabled, []}, Pipeline.pump_dispatcher())
    assert match?({:error, :dispatch_disabled}, Pipeline.dispatch_now("tsk_dummy"))
    assert Pipeline.retry_timers() == %{}
    assert :ok = Pipeline.rearm_pending_retries()
    assert :ok = Pipeline.cancel_retry_timer("tsk_dummy")
    assert {:error, :not_waiting_to_retry} = Pipeline.arm_retry_timer("tsk_dummy")
  end

  test "delegates stage lifecycle and gate actions", %{project: project, task: task, roles: roles} do
    _arch = roles[:architect]
    _eng = roles[:engineer]

    {:ok, task_approve} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :architect,
        stage_state: :awaiting_approval
      })

    assert {:ok, %Task{stage: :engineer}} = Pipeline.approve_stage(task_approve)

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_pipeline_context_10202",
      "identifier" => "TSK-10202",
      "title" => "Task 10202"
    })

    {:ok, issue_10202} = Issues.capture_issue(system_scope(), project, "Task 10202")

    LinearMock.mock_update_issue_success(%{"id" => "lin_task_pipeline_context_10202"})

    {:ok, task_request} = Pipeline.bring_local(system_scope(), issue_10202)

    {:ok, task_request} =
      Pipeline.update_task(system_scope(), task_request.id, %{
        stage: :architect,
        stage_state: :awaiting_approval
      })

    assert {:ok, %Task{stage: :architect, stage_state: :queued}} = Pipeline.request_changes(task_request, "Fix schema")

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_pipeline_context_10203",
      "identifier" => "TSK-10203",
      "title" => "Task 10203"
    })

    {:ok, issue_10203} = Issues.capture_issue(system_scope(), project, "Task 10203")

    LinearMock.mock_update_issue_success(%{"id" => "lin_task_pipeline_context_10203"})

    {:ok, task_send_back} = Pipeline.bring_local(system_scope(), issue_10203)

    {:ok, task_send_back} =
      Pipeline.update_task(system_scope(), task_send_back.id, %{
        stage: :review,
        stage_state: :awaiting_approval
      })

    assert {:ok, %Task{stage: :engineer, stage_state: :queued}} =
             Pipeline.send_back_to_engineer(task_send_back, "Rework please")

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_pipeline_context_10204",
      "identifier" => "TSK-10204",
      "title" => "Task 10204"
    })

    {:ok, issue_10204} = Issues.capture_issue(system_scope(), project, "Task 10204")

    LinearMock.mock_update_issue_success(%{"id" => "lin_task_pipeline_context_10204"})

    {:ok, task_skip} = Pipeline.bring_local(system_scope(), issue_10204)

    {:ok, task_skip} =
      Pipeline.update_task(system_scope(), task_skip.id, %{
        stage: :review,
        stage_state: :awaiting_approval
      })

    assert {:ok, %Task{stage: :ready_to_merge, stage_state: :awaiting_approval}} =
             Pipeline.skip_to_ready_to_merge(task_skip)

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_pipeline_context_10205",
      "identifier" => "TSK-10205",
      "title" => "Task 10205"
    })

    {:ok, issue_10205} = Issues.capture_issue(system_scope(), project, "Task 10205")

    LinearMock.mock_update_issue_success(%{"id" => "lin_task_pipeline_context_10205"})

    {:ok, task_retry} = Pipeline.bring_local(system_scope(), issue_10205)

    {:ok, task_retry} =
      Pipeline.update_task(system_scope(), task_retry.id, %{
        stage: :engineer,
        stage_state: :failed
      })

    assert {:ok, %Task{stage_state: :queued}} = Pipeline.retry_stage(task_retry)

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_pipeline_context_10206",
      "identifier" => "TSK-10206",
      "title" => "Task 10206"
    })

    {:ok, issue_10206} = Issues.capture_issue(system_scope(), project, "Task 10206")

    LinearMock.mock_update_issue_success(%{"id" => "lin_task_pipeline_context_10206"})

    {:ok, task_retry_opts} = Pipeline.bring_local(system_scope(), issue_10206)

    {:ok, task_retry_opts} =
      Pipeline.update_task(system_scope(), task_retry_opts.id, %{
        stage: :engineer,
        stage_state: :failed
      })

    assert {:ok, %Task{stage_state: :queued}} =
             Pipeline.retry_stage(Scope.for_system(), task_retry_opts.id, [])
  end

  test "delegates question lifecycle and listing actions", %{project: project, task: task, roles: roles} do
    role = roles[:engineer]
    _review_role = roles[:review]

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :engineer,
        stage_state: :running
      })

    {:ok, role_run} =
      Runs.create_role_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :running,
        started_at: DateTime.utc_now(),
        exit_code: 0
      })

    scope = Scope.for_system()

    assert {:ok, %Question{id: q_id, prompt: "DB?"}} =
             Pipeline.register_question(task, role_run, %{prompt: "DB?"}, [])

    assert {:ok, %Question{id: ^q_id}} = Pipeline.get_question(scope, q_id)
    assert %Question{id: ^q_id} = Pipeline.get_question!(scope, q_id)

    assert [%Question{id: ^q_id}] =
             Pipeline.list_questions(scope, project.id, status: :pending)

    assert [%Question{id: ^q_id}] =
             Pipeline.list_pending_questions(scope, project.id, [])

    assert {:ok, %Task{stage: :review, stage_state: :queued}} = Pipeline.release_blocked_stage(scope, task.id)

    assert {:ok, %Question{status: :answered}} =
             Pipeline.answer_question(scope, q_id, "Postgres")

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_pipeline_dismiss",
      "identifier" => "PLC-9",
      "title" => "Dismissable Task"
    })

    {:ok, dismiss_issue} = Issues.capture_issue(scope, project, "Dismissable Task")
    LinearMock.mock_update_issue_success(%{"id" => "lin_pipeline_dismiss"})
    {:ok, dismiss_task} = Pipeline.bring_local(scope, dismiss_issue)

    {:ok, q_dismiss} = Pipeline.register_question(dismiss_task, %{prompt: "Drop this?"})

    assert {:ok, %Question{status: :dismissed}} =
             Pipeline.dismiss_question(scope, q_dismiss.id)
  end

  test "delegates design stage actions and helpers", %{task: task} do
    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :product
      })

    scope = Scope.for_system()

    assert Pipeline.uses_design?(task)
    assert Pipeline.uses_design?(task, [])

    # recheck_design with 3 args
    assert {:ok, %Task{stage: :product}} = Pipeline.recheck_design(scope, task.id, [])

    # apply_design_manifest with 3 args
    assert {:error, _reason} = Pipeline.apply_design_manifest(scope, task, [])
  end

  test "delegates demo stage actions and helpers", %{project: project, task: task, roles: roles} do
    _demo_role = roles[:demo]
    scope = Scope.for_system()
    worktree = create_temp_git_repo()

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :ready_to_merge,
        stage_state: :awaiting_approval,
        worktree_path: worktree
      })

    demo_manifest_10701 =
      Jason.encode!(%{
        "version" => 1,
        "outcome" => "recorded",
        "segments" => [
          %{
            "criterionIndex" => 1,
            "criterion" => "Feature works",
            "outcome" => "recorded",
            "frames" => [%{"path" => "frame-1.png", "holdMs" => 1000, "caption" => "Step 1"}]
          }
        ]
      })

    expect(File, :exists?, fn _path -> true end)

    expect(File, :read, fn _path -> {:ok, demo_manifest_10701} end)

    expect(File, :stat, fn _path -> {:ok, %File.Stat{type: :regular, size: 128}} end)

    expect(File, :read, fn _path -> {:ok, "PNG_FRAME"} end)

    mock_demo_uploads(1)

    LinearMock.mock_create_comment_success(%{
      "id" => "cmt_demo_10701",
      "body" => "Demo",
      "createdAt" => "2026-09-05T12:00:00.000Z"
    })

    {:ok, _demo} =
      Artifacts.capture_demo(system_scope(), task, "/tmp/rail_scratch/demo_10701")

    # can_rerecord_demo?
    assert Pipeline.can_rerecord_demo?(task)

    # rerecord_demo with task
    assert {:ok, %Task{stage: :demo, stage_state: :queued}} =
             Pipeline.rerecord_demo(task)

    # rerecord_demo with 3 args (scope, id, opts)
    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_pipeline_context_10207",
      "identifier" => "TSK-10207",
      "title" => "Task 10207"
    })

    {:ok, issue_10207} = Issues.capture_issue(system_scope(), project, "Task 10207")

    LinearMock.mock_update_issue_success(%{"id" => "lin_task_pipeline_context_10207"})

    {:ok, task2} = Pipeline.bring_local(system_scope(), issue_10207)

    {:ok, task2} =
      Pipeline.update_task(system_scope(), task2.id, %{
        stage: :ready_to_merge,
        stage_state: :awaiting_approval,
        worktree_path: worktree
      })

    demo_manifest_10702 =
      Jason.encode!(%{
        "version" => 1,
        "outcome" => "recorded",
        "segments" => [
          %{
            "criterionIndex" => 1,
            "criterion" => "Feature works",
            "outcome" => "recorded",
            "frames" => [%{"path" => "frame-1.png", "holdMs" => 1000, "caption" => "Step 1"}]
          }
        ]
      })

    expect(File, :exists?, fn _path -> true end)

    expect(File, :read, fn _path -> {:ok, demo_manifest_10702} end)

    expect(File, :stat, fn _path -> {:ok, %File.Stat{type: :regular, size: 128}} end)

    expect(File, :read, fn _path -> {:ok, "PNG_FRAME"} end)

    mock_demo_uploads(1)

    LinearMock.mock_create_comment_success(%{
      "id" => "cmt_demo_10702",
      "body" => "Demo",
      "createdAt" => "2026-09-05T12:00:00.000Z"
    })

    {:ok, _demo} =
      Artifacts.capture_demo(system_scope(), task2, "/tmp/rail_scratch/demo_10702")

    assert {:ok, %Task{stage: :demo, stage_state: :queued}} =
             Pipeline.rerecord_demo(scope, task2.id, [])

    # decline_demo with task
    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_pipeline_context_10208",
      "identifier" => "TSK-10208",
      "title" => "Task 10208"
    })

    {:ok, issue_10208} = Issues.capture_issue(system_scope(), project, "Task 10208")

    LinearMock.mock_update_issue_success(%{"id" => "lin_task_pipeline_context_10208"})

    {:ok, task3} = Pipeline.bring_local(system_scope(), issue_10208)

    {:ok, task3} =
      Pipeline.update_task(system_scope(), task3.id, %{
        stage: :demo,
        stage_state: :queued
      })

    assert {:ok, %Task{stage: :ready_to_merge, stage_state: :awaiting_approval}} =
             Pipeline.decline_demo(task3, "Skipping demo recording")

    # decline_demo with 3 args (scope, id, opts)
    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_pipeline_context_10209",
      "identifier" => "TSK-10209",
      "title" => "Task 10209"
    })

    {:ok, issue_10209} = Issues.capture_issue(system_scope(), project, "Task 10209")

    LinearMock.mock_update_issue_success(%{"id" => "lin_task_pipeline_context_10209"})

    {:ok, task4} = Pipeline.bring_local(system_scope(), issue_10209)

    {:ok, task4} =
      Pipeline.update_task(system_scope(), task4.id, %{
        stage: :demo,
        stage_state: :queued
      })

    assert {:ok, %Task{stage: :ready_to_merge, stage_state: :awaiting_approval}} =
             Pipeline.decline_demo(scope, task4.id, reason: "3 arg decline")

    # refresh_demo_freshness arities
    assert {:ok, %Task{}} = Pipeline.refresh_demo_freshness(task)
    assert {:ok, %Task{}} = Pipeline.refresh_demo_freshness(task, [])
    assert {:ok, %Task{}} = Pipeline.refresh_demo_freshness(scope, task.id, [])
  end
end
