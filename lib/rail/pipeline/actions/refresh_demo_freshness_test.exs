defmodule Rail.Pipeline.Actions.RefreshDemoFreshnessTest do
  use Rail.DataCase, async: true

  import RailTest.PipelineHelpers

  alias Rail.Artifacts
  alias Rail.Artifacts.Schemas.Demo
  alias Rail.Git
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
        name: "Demo Freshness Workspace",
        external_id: "lin_ws_demo_freshness",
        token: "lin_api_token_demo_freshness",
        webhook_secret: "whsec_demo_freshness"
      })

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Demo Freshness Project 9501",
        github_repo: "org/demo-freshness-9501",
        github_installation_id: 9501,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_demo_freshness_9501",
        linear_team_key: "P9501",
        clone_path: "/tmp/repos/demo-freshness-9501",
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
      "id" => "lin_demo_freshness_1",
      "identifier" => "DFR-1",
      "title" => "Demo Freshness Issue"
    })

    {:ok, issue} = Issues.capture_issue(scope, project, "Demo Freshness Issue")

    {:ok, task} = Pipeline.create_task(issue, :product)

    %{project: project, issue: issue, task: task, roles: roles}
  end

  test "no-op when task is merged or has no demo", %{project: project, task: task} do
    worktree = create_temp_git_repo()

    {:ok, task_merged} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :merged,
        stage_state: :awaiting_approval,
        worktree_path: worktree
      })

    assert {:ok, %Task{stage: :merged}} = Pipeline.refresh_demo_freshness(task_merged)

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_demo_freshness_9502",
      "identifier" => "TSK-9502",
      "title" => "Task 9502"
    })

    {:ok, issue_9502} = Issues.capture_issue(system_scope(), project, "Task 9502")

    {:ok, task_merged_at} = Pipeline.create_task(issue_9502, :product)

    {:ok, task_merged_at} =
      Pipeline.update_task(system_scope(), task_merged_at.id, %{
        stage: :ready_to_merge,
        stage_state: :awaiting_approval,
        worktree_path: worktree,
        merged_at: DateTime.utc_now()
      })

    assert {:ok, %Task{stage: :ready_to_merge}} = Pipeline.refresh_demo_freshness(task_merged_at)

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_demo_freshness_9503",
      "identifier" => "TSK-9503",
      "title" => "Task 9503"
    })

    {:ok, issue_9503} = Issues.capture_issue(system_scope(), project, "Task 9503")

    {:ok, task_no_demo} = Pipeline.create_task(issue_9503, :product)

    {:ok, task_no_demo} =
      Pipeline.update_task(system_scope(), task_no_demo.id, %{
        stage: :ready_to_merge,
        stage_state: :awaiting_approval,
        worktree_path: worktree
      })

    assert {:ok, %Task{stage: :ready_to_merge}} = Pipeline.refresh_demo_freshness(task_no_demo)
  end

  test "no-op when demo is already stale or worktree path is invalid", %{project: project, task: task} do
    worktree = create_temp_git_repo()

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :ready_to_merge,
        stage_state: :awaiting_approval,
        worktree_path: worktree
      })

    demo_scratch_10001 = Path.join("/tmp", "rail_demo_scratch_#{System.unique_integer([:positive])}")

    demo_scratch_dir_10001 = Path.join([demo_scratch_10001, "demo"])

    File.mkdir_p!(demo_scratch_dir_10001)

    on_exit(fn -> File.rm_rf(demo_scratch_10001) end)

    File.write!(Path.join(demo_scratch_dir_10001, "frame-1.png"), "fake demo frame")

    File.write!(
      Path.join(demo_scratch_dir_10001, "manifest.json"),
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
      "id" => "cmt_demo_10001",
      "body" => "Demo",
      "createdAt" => "2026-09-05T12:00:00.000Z"
    })

    {:ok, _demo} =
      Artifacts.capture_demo(system_scope(), task, demo_scratch_10001,
        head_sha: "old_sha",
        dirty_digest: "old_digest"
      )

    {:ok, _stale} = Artifacts.mark_demo_stale(system_scope(), task)

    assert {:ok, %Task{stage: :ready_to_merge}} = Pipeline.refresh_demo_freshness(task)

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_demo_freshness_9504",
      "identifier" => "TSK-9504",
      "title" => "Task 9504"
    })

    {:ok, issue_9504} = Issues.capture_issue(system_scope(), project, "Task 9504")

    {:ok, task_missing_dir} = Pipeline.create_task(issue_9504, :product)

    {:ok, task_missing_dir} =
      Pipeline.update_task(system_scope(), task_missing_dir.id, %{
        stage: :ready_to_merge,
        stage_state: :awaiting_approval,
        worktree_path: "/tmp/nonexistent_#{System.unique_integer([:positive])}"
      })

    demo_scratch_10002 = Path.join("/tmp", "rail_demo_scratch_#{System.unique_integer([:positive])}")

    demo_scratch_dir_10002 = Path.join([demo_scratch_10002, "demo"])

    File.mkdir_p!(demo_scratch_dir_10002)

    on_exit(fn -> File.rm_rf(demo_scratch_10002) end)

    File.write!(Path.join(demo_scratch_dir_10002, "frame-1.png"), "fake demo frame")

    File.write!(
      Path.join(demo_scratch_dir_10002, "manifest.json"),
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
      "id" => "cmt_demo_10002",
      "body" => "Demo",
      "createdAt" => "2026-09-05T12:00:00.000Z"
    })

    {:ok, _demo} =
      Artifacts.capture_demo(system_scope(), task_missing_dir, demo_scratch_10002,
        head_sha: "some_sha",
        dirty_digest: "some_digest"
      )

    assert {:ok, %Task{stage: :ready_to_merge}} = Pipeline.refresh_demo_freshness(task_missing_dir)

    # Non-git directory worktree
    scratch_dir = Path.join("/tmp", "rail_non_git_#{System.unique_integer([:positive])}")
    File.mkdir_p!(scratch_dir)
    on_exit(fn -> File.rm_rf(scratch_dir) end)

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_demo_freshness_9505",
      "identifier" => "TSK-9505",
      "title" => "Task 9505"
    })

    {:ok, issue_9505} = Issues.capture_issue(system_scope(), project, "Task 9505")

    {:ok, task_non_git} = Pipeline.create_task(issue_9505, :product)

    {:ok, task_non_git} =
      Pipeline.update_task(system_scope(), task_non_git.id, %{
        stage: :ready_to_merge,
        stage_state: :awaiting_approval,
        worktree_path: scratch_dir
      })

    demo_scratch_10003 = Path.join("/tmp", "rail_demo_scratch_#{System.unique_integer([:positive])}")

    demo_scratch_dir_10003 = Path.join([demo_scratch_10003, "demo"])

    File.mkdir_p!(demo_scratch_dir_10003)

    on_exit(fn -> File.rm_rf(demo_scratch_10003) end)

    File.write!(Path.join(demo_scratch_dir_10003, "frame-1.png"), "fake demo frame")

    File.write!(
      Path.join(demo_scratch_dir_10003, "manifest.json"),
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
      "id" => "cmt_demo_10003",
      "body" => "Demo",
      "createdAt" => "2026-09-05T12:00:00.000Z"
    })

    {:ok, _demo} =
      Artifacts.capture_demo(system_scope(), task_non_git, demo_scratch_10003,
        head_sha: "some_sha",
        dirty_digest: "some_digest"
      )

    assert {:ok, %Task{stage: :ready_to_merge}} = Pipeline.refresh_demo_freshness(task_non_git)

    # Nil worktree path
    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_demo_freshness_9506",
      "identifier" => "TSK-9506",
      "title" => "Task 9506"
    })

    {:ok, issue_9506} = Issues.capture_issue(system_scope(), project, "Task 9506")

    {:ok, task_nil_worktree} = Pipeline.create_task(issue_9506, :product)

    {:ok, task_nil_worktree} =
      Pipeline.update_task(system_scope(), task_nil_worktree.id, %{
        stage: :ready_to_merge,
        stage_state: :awaiting_approval,
        worktree_path: nil
      })

    demo_scratch_10004 = Path.join("/tmp", "rail_demo_scratch_#{System.unique_integer([:positive])}")

    demo_scratch_dir_10004 = Path.join([demo_scratch_10004, "demo"])

    File.mkdir_p!(demo_scratch_dir_10004)

    on_exit(fn -> File.rm_rf(demo_scratch_10004) end)

    File.write!(Path.join(demo_scratch_dir_10004, "frame-1.png"), "fake demo frame")

    File.write!(
      Path.join(demo_scratch_dir_10004, "manifest.json"),
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
      "id" => "cmt_demo_10004",
      "body" => "Demo",
      "createdAt" => "2026-09-05T12:00:00.000Z"
    })

    {:ok, _demo} =
      Artifacts.capture_demo(system_scope(), task_nil_worktree, demo_scratch_10004,
        head_sha: "some_sha",
        dirty_digest: "some_digest"
      )

    assert {:ok, %Task{stage: :ready_to_merge}} = Pipeline.refresh_demo_freshness(task_nil_worktree)
    assert {:ok, %Task{}} = Pipeline.refresh_demo_freshness(Scope.user_scope(), task_nil_worktree.id, [])
    assert {:error, :not_found} = Pipeline.refresh_demo_freshness(Scope.for_system(), :bad_id, [])
  end

  test "leaves demo fresh and task at ready_to_merge when fingerprint matches", %{task: task} do
    worktree = create_temp_git_repo()
    %{head_sha: sha, dirty_digest: digest} = Git.branch_fingerprint(worktree, ignore_rail: true)

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :ready_to_merge,
        stage_state: :awaiting_approval,
        worktree_path: worktree
      })

    demo_scratch_10005 = Path.join("/tmp", "rail_demo_scratch_#{System.unique_integer([:positive])}")

    demo_scratch_dir_10005 = Path.join([demo_scratch_10005, "demo"])

    File.mkdir_p!(demo_scratch_dir_10005)

    on_exit(fn -> File.rm_rf(demo_scratch_10005) end)

    File.write!(Path.join(demo_scratch_dir_10005, "frame-1.png"), "fake demo frame")

    File.write!(
      Path.join(demo_scratch_dir_10005, "manifest.json"),
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
      "id" => "cmt_demo_10005",
      "body" => "Demo",
      "createdAt" => "2026-09-05T12:00:00.000Z"
    })

    {:ok, demo} =
      Artifacts.capture_demo(system_scope(), task, demo_scratch_10005,
        head_sha: sha,
        dirty_digest: digest
      )

    assert {:ok, %Task{stage: :ready_to_merge, stage_state: :awaiting_approval}} =
             Pipeline.refresh_demo_freshness(task)

    refute Repo.get!(Demo, demo.id).stale
  end

  test "re-queues ready_to_merge task to demo queued when commit changes", %{task: task} do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")
    worktree = create_temp_git_repo()
    %{dirty_digest: current_digest} = Git.branch_fingerprint(worktree, ignore_rail: true)

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :ready_to_merge,
        stage_state: :awaiting_approval,
        worktree_path: worktree
      })

    demo_scratch_10006 = Path.join("/tmp", "rail_demo_scratch_#{System.unique_integer([:positive])}")

    demo_scratch_dir_10006 = Path.join([demo_scratch_10006, "demo"])

    File.mkdir_p!(demo_scratch_dir_10006)

    on_exit(fn -> File.rm_rf(demo_scratch_10006) end)

    File.write!(Path.join(demo_scratch_dir_10006, "frame-1.png"), "fake demo frame")

    File.write!(
      Path.join(demo_scratch_dir_10006, "manifest.json"),
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
      "id" => "cmt_demo_10006",
      "body" => "Demo",
      "createdAt" => "2026-09-05T12:00:00.000Z"
    })

    {:ok, demo} =
      Artifacts.capture_demo(system_scope(), task, demo_scratch_10006,
        head_sha: "old_commit_sha",
        dirty_digest: current_digest
      )

    assert {:ok,
            %Task{
              id: task_id,
              stage: :demo,
              stage_state: :queued,
              error: nil
            }} = Pipeline.refresh_demo_freshness(Scope.for_system(), task.id, [])

    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :demo_stale_requeued}}

    assert Repo.get!(Demo, demo.id).stale
    assert Repo.get!(Task, task.id).stage == :demo
    assert Repo.get!(Task, task.id).stage_state == :queued
  end

  test "re-queues ready_to_merge task to demo queued when dirty digest changes", %{task: task} do
    worktree = create_temp_git_repo()
    %{head_sha: current_sha} = Git.branch_fingerprint(worktree, ignore_rail: true)

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :ready_to_merge,
        stage_state: :awaiting_approval,
        worktree_path: worktree
      })

    demo_scratch_10007 = Path.join("/tmp", "rail_demo_scratch_#{System.unique_integer([:positive])}")

    demo_scratch_dir_10007 = Path.join([demo_scratch_10007, "demo"])

    File.mkdir_p!(demo_scratch_dir_10007)

    on_exit(fn -> File.rm_rf(demo_scratch_10007) end)

    File.write!(Path.join(demo_scratch_dir_10007, "frame-1.png"), "fake demo frame")

    File.write!(
      Path.join(demo_scratch_dir_10007, "manifest.json"),
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
      "id" => "cmt_demo_10007",
      "body" => "Demo",
      "createdAt" => "2026-09-05T12:00:00.000Z"
    })

    {:ok, demo} =
      Artifacts.capture_demo(system_scope(), task, demo_scratch_10007,
        head_sha: current_sha,
        dirty_digest: "outdated_digest"
      )

    assert {:ok, %Task{stage: :demo, stage_state: :queued}} = Pipeline.refresh_demo_freshness(task)

    assert Repo.get!(Demo, demo.id).stale
  end

  test "marks demo stale but preserves earlier stage when commit changes", %{task: task} do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")
    worktree = create_temp_git_repo()

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :review,
        stage_state: :queued,
        worktree_path: worktree
      })

    demo_scratch_10008 = Path.join("/tmp", "rail_demo_scratch_#{System.unique_integer([:positive])}")

    demo_scratch_dir_10008 = Path.join([demo_scratch_10008, "demo"])

    File.mkdir_p!(demo_scratch_dir_10008)

    on_exit(fn -> File.rm_rf(demo_scratch_10008) end)

    File.write!(Path.join(demo_scratch_dir_10008, "frame-1.png"), "fake demo frame")

    File.write!(
      Path.join(demo_scratch_dir_10008, "manifest.json"),
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
      "id" => "cmt_demo_10008",
      "body" => "Demo",
      "createdAt" => "2026-09-05T12:00:00.000Z"
    })

    {:ok, demo} =
      Artifacts.capture_demo(system_scope(), task, demo_scratch_10008,
        head_sha: "previous_commit",
        dirty_digest: "previous_digest"
      )

    assert {:ok, %Task{id: task_id, stage: :review, stage_state: :queued}} =
             Pipeline.refresh_demo_freshness(task)

    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :demo_marked_stale}}

    assert Repo.get!(Demo, demo.id).stale
    assert Repo.get!(Task, task.id).stage == :review
    assert Repo.get!(Task, task.id).stage_state == :queued
  end

  test "marks demo stale but preserves running task state when task is busy", %{task: task} do
    worktree = create_temp_git_repo()

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :ready_to_merge,
        stage_state: :running,
        worktree_path: worktree
      })

    demo_scratch_10009 = Path.join("/tmp", "rail_demo_scratch_#{System.unique_integer([:positive])}")

    demo_scratch_dir_10009 = Path.join([demo_scratch_10009, "demo"])

    File.mkdir_p!(demo_scratch_dir_10009)

    on_exit(fn -> File.rm_rf(demo_scratch_10009) end)

    File.write!(Path.join(demo_scratch_dir_10009, "frame-1.png"), "fake demo frame")

    File.write!(
      Path.join(demo_scratch_dir_10009, "manifest.json"),
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
      "id" => "cmt_demo_10009",
      "body" => "Demo",
      "createdAt" => "2026-09-05T12:00:00.000Z"
    })

    {:ok, demo} =
      Artifacts.capture_demo(system_scope(), task, demo_scratch_10009,
        head_sha: "different_sha",
        dirty_digest: "different_digest"
      )

    assert {:ok, %Task{stage: :ready_to_merge, stage_state: :running}} =
             Pipeline.refresh_demo_freshness(task)

    assert Repo.get!(Demo, demo.id).stale
  end

  test "enforces authorization", %{task: task} do
    assert {:error, :not_authorized} =
             Pipeline.refresh_demo_freshness(%Scope{system: false, user: nil}, task)
  end

  test "returns not found for unknown task" do
    assert {:error, :not_found} =
             Pipeline.refresh_demo_freshness("tsk_nonexistent_9999")
  end
end
