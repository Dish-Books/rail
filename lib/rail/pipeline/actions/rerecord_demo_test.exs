defmodule Rail.Pipeline.Actions.RerecordDemoTest do
  use Rail.DataCase, async: true

  import RailTest.PipelineHelpers

  alias Rail.Artifacts
  alias Rail.Artifacts.Schemas.Demo
  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Scope
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    scope = system_scope()

    {:ok, workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Rerecord Demo Workspace",
        external_id: "lin_ws_rerecord_demo",
        token: "lin_api_token_rerecord_demo",
        webhook_secret: "whsec_rerecord_demo"
      })

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Rerecord Demo Project 9401",
        github_repo: "org/rerecord-demo-9401",
        github_installation_id: 9401,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_rerecord_demo_9401",
        linear_team_key: "P9401",
        clone_path: "/tmp/repos/rerecord-demo-9401",
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
      "id" => "lin_rerecord_demo_1",
      "identifier" => "RRD-1",
      "title" => "Rerecord Demo Issue"
    })

    {:ok, issue} = Issues.capture_issue(scope, project, "Rerecord Demo Issue")

    LinearMock.mock_update_issue_success(%{"id" => "lin_rerecord_demo_1"})

    {:ok, task} = Pipeline.create_task(issue)

    %{project: project, issue: issue, task: task, roles: roles}
  end

  test "marks latest demo stale, resets task to demo queued, broadcasts and pumps dispatcher", %{task: task} do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")
    worktree = create_temp_git_repo()

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :ready_to_merge,
        stage_state: :awaiting_approval,
        worktree_path: worktree,
        error: "Previous failure"
      })

    demo_scratch_9901 = Path.join("/tmp", "rail_demo_scratch_#{System.unique_integer([:positive])}")
    demo_dir_9901 = Path.join(demo_scratch_9901, "demo")
    File.mkdir_p!(demo_dir_9901)
    on_exit(fn -> File.rm_rf(demo_scratch_9901) end)

    File.write!(Path.join(demo_dir_9901, "frame-1.png"), "fake demo frame")

    File.write!(
      Path.join(demo_dir_9901, "manifest.json"),
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
    )

    mock_demo_uploads(1)

    LinearMock.mock_create_comment_success(%{
      "id" => "cmt_demo_9901",
      "body" => "Demo",
      "createdAt" => "2026-09-05T12:00:00.000Z"
    })

    {:ok, demo} =
      Artifacts.capture_demo(system_scope(), task, demo_scratch_9901)

    assert {:ok,
            %Task{
              id: task_id,
              stage: :demo,
              stage_state: :queued,
              error: nil,
              retry_after: nil
            }} = Pipeline.rerecord_demo(task)

    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :demo_rerecord}}

    assert %Demo{stale: true} = Repo.get!(Demo, demo.id)
  end

  test "rerecord_demo succeeds even when no previous demo exists", %{task: task} do
    worktree = create_temp_git_repo()

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :demo,
        stage_state: :failed,
        worktree_path: worktree,
        error: "Recording failed"
      })

    assert {:ok, %Task{stage: :demo, stage_state: :queued, error: nil}} =
             Pipeline.rerecord_demo(Scope.user_scope(), task.id, [])

    assert {:error, :not_found} = Pipeline.rerecord_demo(Scope.for_system(), :bad_id, [])
  end

  test "guards against merged tasks", %{project: project, task: task} do
    worktree = create_temp_git_repo()

    {:ok, task_merged_stage} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :merged,
        stage_state: :awaiting_approval,
        worktree_path: worktree
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_rerecord_demo_9402",
      "identifier" => "TSK-9402",
      "title" => "Task 9402"
    })

    {:ok, issue_9402} = Issues.capture_issue(system_scope(), project, "Task 9402")

    LinearMock.mock_update_issue_success(%{"id" => "lin_task_rerecord_demo_9402"})

    {:ok, task_merged_at} = Pipeline.create_task(issue_9402)

    {:ok, task_merged_at} =
      Pipeline.update_task(system_scope(), task_merged_at.id, %{
        stage: :ready_to_merge,
        stage_state: :awaiting_approval,
        worktree_path: worktree,
        merged_at: DateTime.utc_now()
      })

    assert {:error, :task_merged} = Pipeline.rerecord_demo(task_merged_stage)
    assert {:error, :task_merged} = Pipeline.rerecord_demo(task_merged_at)
  end

  test "guards against missing worktree directory on disk", %{project: project, task: task} do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")
    nonexistent_path = "/tmp/nonexistent_worktree_#{System.unique_integer([:positive])}"

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :ready_to_merge,
        stage_state: :awaiting_approval,
        worktree_path: nonexistent_path
      })

    assert {:error, :no_worktree} = Pipeline.rerecord_demo(task)

    assert_receive {:pipeline_changed, %{task_id: task_id, event: :rerecord_demo_failed}}
    assert task_id == task.id

    reloaded = Repo.get!(Task, task.id)
    assert reloaded.error == "Worktree does not exist on disk (#{nonexistent_path})."

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_rerecord_demo_9403",
      "identifier" => "TSK-9403",
      "title" => "Task 9403"
    })

    {:ok, issue_9403} = Issues.capture_issue(system_scope(), project, "Task 9403")

    LinearMock.mock_update_issue_success(%{"id" => "lin_task_rerecord_demo_9403"})

    {:ok, task_nil_worktree} = Pipeline.create_task(issue_9403)

    {:ok, task_nil_worktree} =
      Pipeline.update_task(system_scope(), task_nil_worktree.id, %{
        stage: :ready_to_merge,
        stage_state: :awaiting_approval,
        worktree_path: nil
      })

    assert {:error, :no_worktree} = Pipeline.rerecord_demo(task_nil_worktree)
    reloaded_nil = Repo.get!(Task, task_nil_worktree.id)
    assert reloaded_nil.error == "Worktree does not exist on disk ()."
  end

  test "can_rerecord_demo? checks eligibility accurately", %{project: project, task: task} do
    worktree = create_temp_git_repo()

    {:ok, eligible_ready} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :ready_to_merge,
        stage_state: :awaiting_approval,
        worktree_path: worktree
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_rerecord_demo_9404",
      "identifier" => "TSK-9404",
      "title" => "Task 9404"
    })

    {:ok, issue_9404} = Issues.capture_issue(system_scope(), project, "Task 9404")

    LinearMock.mock_update_issue_success(%{"id" => "lin_task_rerecord_demo_9404"})

    {:ok, eligible_demo_failed} = Pipeline.create_task(issue_9404)

    {:ok, eligible_demo_failed} =
      Pipeline.update_task(system_scope(), eligible_demo_failed.id, %{
        stage: :demo,
        stage_state: :failed,
        worktree_path: worktree
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_rerecord_demo_9405",
      "identifier" => "TSK-9405",
      "title" => "Task 9405"
    })

    {:ok, issue_9405} = Issues.capture_issue(system_scope(), project, "Task 9405")

    LinearMock.mock_update_issue_success(%{"id" => "lin_task_rerecord_demo_9405"})

    {:ok, busy_task} = Pipeline.create_task(issue_9405)

    {:ok, busy_task} =
      Pipeline.update_task(system_scope(), busy_task.id, %{
        stage: :ready_to_merge,
        stage_state: :running,
        worktree_path: worktree
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_rerecord_demo_9406",
      "identifier" => "TSK-9406",
      "title" => "Task 9406"
    })

    {:ok, issue_9406} = Issues.capture_issue(system_scope(), project, "Task 9406")

    LinearMock.mock_update_issue_success(%{"id" => "lin_task_rerecord_demo_9406"})

    {:ok, merged_task} = Pipeline.create_task(issue_9406)

    {:ok, merged_task} =
      Pipeline.update_task(system_scope(), merged_task.id, %{
        stage: :merged,
        stage_state: :awaiting_approval,
        worktree_path: worktree
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_rerecord_demo_9407",
      "identifier" => "TSK-9407",
      "title" => "Task 9407"
    })

    {:ok, issue_9407} = Issues.capture_issue(system_scope(), project, "Task 9407")

    LinearMock.mock_update_issue_success(%{"id" => "lin_task_rerecord_demo_9407"})

    {:ok, missing_path_task} = Pipeline.create_task(issue_9407)

    {:ok, missing_path_task} =
      Pipeline.update_task(system_scope(), missing_path_task.id, %{
        stage: :ready_to_merge,
        stage_state: :awaiting_approval,
        worktree_path: nil
      })

    assert Pipeline.can_rerecord_demo?(eligible_ready)
    assert Pipeline.can_rerecord_demo?(eligible_demo_failed)
    refute Pipeline.can_rerecord_demo?(busy_task)
    refute Pipeline.can_rerecord_demo?(merged_task)
    refute Pipeline.can_rerecord_demo?(missing_path_task)
    refute Pipeline.can_rerecord_demo?(nil)
  end

  test "enforces authorization", %{task: task} do
    assert {:error, :not_authorized} =
             Pipeline.rerecord_demo(%Scope{system: false, user: nil}, task)
  end

  test "returns not found for unknown task" do
    assert {:error, :not_found} =
             Pipeline.rerecord_demo("tsk_nonexistent_9999")
  end
end
