defmodule Rail.Pipeline.Actions.RefreshDemoFreshnessTest do
  use Rail.DataCase, async: false

  alias Rail.Artifacts.Schemas.Demo
  alias Rail.Git
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Scope

  test "no-op when task is merged or has no demo" do
    project = create_test_project()
    worktree = create_temp_git_repo()

    task_merged =
      create_test_task(%{
        project_id: project.id,
        stage: :merged,
        stage_state: :awaiting_approval,
        worktree_path: worktree
      })

    assert {:ok, %Task{stage: :merged}} = Pipeline.refresh_demo_freshness(task_merged)

    task_merged_at =
      create_test_task(%{
        project_id: project.id,
        stage: :ready_to_merge,
        stage_state: :awaiting_approval,
        worktree_path: worktree,
        merged_at: DateTime.utc_now()
      })

    assert {:ok, %Task{stage: :ready_to_merge}} = Pipeline.refresh_demo_freshness(task_merged_at)

    task_no_demo =
      create_test_task(%{
        project_id: project.id,
        stage: :ready_to_merge,
        stage_state: :awaiting_approval,
        worktree_path: worktree
      })

    assert {:ok, %Task{stage: :ready_to_merge}} = Pipeline.refresh_demo_freshness(task_no_demo)
  end

  test "no-op when demo is already stale or worktree path is invalid" do
    project = create_test_project()
    worktree = create_temp_git_repo()

    task =
      create_test_task(%{
        project_id: project.id,
        stage: :ready_to_merge,
        stage_state: :awaiting_approval,
        worktree_path: worktree
      })

    create_test_demo(%{
      task_id: task.id,
      version: 1,
      stale: true,
      head_sha: "old_sha",
      dirty_digest: "old_digest"
    })

    assert {:ok, %Task{stage: :ready_to_merge}} = Pipeline.refresh_demo_freshness(task)

    task_missing_dir =
      create_test_task(%{
        project_id: project.id,
        stage: :ready_to_merge,
        stage_state: :awaiting_approval,
        worktree_path: "/tmp/nonexistent_#{System.unique_integer([:positive])}"
      })

    create_test_demo(%{
      task_id: task_missing_dir.id,
      version: 1,
      stale: false,
      head_sha: "some_sha",
      dirty_digest: "some_digest"
    })

    assert {:ok, %Task{stage: :ready_to_merge}} = Pipeline.refresh_demo_freshness(task_missing_dir)

    # Non-git directory worktree
    scratch_dir = create_temp_scratch_dir()

    task_non_git =
      create_test_task(%{
        project_id: project.id,
        stage: :ready_to_merge,
        stage_state: :awaiting_approval,
        worktree_path: scratch_dir
      })

    create_test_demo(%{
      task_id: task_non_git.id,
      version: 1,
      stale: false,
      head_sha: "some_sha",
      dirty_digest: "some_digest"
    })

    assert {:ok, %Task{stage: :ready_to_merge}} = Pipeline.refresh_demo_freshness(task_non_git)

    # Nil worktree path
    task_nil_worktree =
      create_test_task(%{
        project_id: project.id,
        stage: :ready_to_merge,
        stage_state: :awaiting_approval,
        worktree_path: nil
      })

    create_test_demo(%{
      task_id: task_nil_worktree.id,
      version: 1,
      stale: false,
      head_sha: "some_sha",
      dirty_digest: "some_digest"
    })

    assert {:ok, %Task{stage: :ready_to_merge}} = Pipeline.refresh_demo_freshness(task_nil_worktree)
    assert {:ok, %Task{}} = Pipeline.refresh_demo_freshness(Scope.user_scope(), task_nil_worktree.id, [])
    assert {:error, :not_found} = Pipeline.refresh_demo_freshness(Scope.for_system(), :bad_id, [])
  end

  test "leaves demo fresh and task at ready_to_merge when fingerprint matches" do
    project = create_test_project()
    worktree = create_temp_git_repo()
    %{head_sha: sha, dirty_digest: digest} = Git.branch_fingerprint(worktree, ignore_rail: true)

    task =
      create_test_task(%{
        project_id: project.id,
        stage: :ready_to_merge,
        stage_state: :awaiting_approval,
        worktree_path: worktree
      })

    demo =
      create_test_demo(%{
        task_id: task.id,
        version: 1,
        stale: false,
        head_sha: sha,
        dirty_digest: digest
      })

    assert {:ok, %Task{stage: :ready_to_merge, stage_state: :awaiting_approval}} =
             Pipeline.refresh_demo_freshness(task)

    refute Repo.get!(Demo, demo.id).stale
  end

  test "re-queues ready_to_merge task to demo queued when commit changes" do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")
    project = create_test_project()
    worktree = create_temp_git_repo()
    %{dirty_digest: current_digest} = Git.branch_fingerprint(worktree, ignore_rail: true)

    task =
      create_test_task(%{
        project_id: project.id,
        stage: :ready_to_merge,
        stage_state: :awaiting_approval,
        worktree_path: worktree
      })

    demo =
      create_test_demo(%{
        task_id: task.id,
        version: 1,
        stale: false,
        head_sha: "old_commit_sha",
        dirty_digest: current_digest
      })

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

  test "re-queues ready_to_merge task to demo queued when dirty digest changes" do
    project = create_test_project()
    worktree = create_temp_git_repo()
    %{head_sha: current_sha} = Git.branch_fingerprint(worktree, ignore_rail: true)

    task =
      create_test_task(%{
        project_id: project.id,
        stage: :ready_to_merge,
        stage_state: :awaiting_approval,
        worktree_path: worktree
      })

    demo =
      create_test_demo(%{
        task_id: task.id,
        version: 1,
        stale: false,
        head_sha: current_sha,
        dirty_digest: "outdated_digest"
      })

    assert {:ok, %Task{stage: :demo, stage_state: :queued}} = Pipeline.refresh_demo_freshness(task)

    assert Repo.get!(Demo, demo.id).stale
  end

  test "marks demo stale but preserves earlier stage when commit changes" do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")
    project = create_test_project()
    worktree = create_temp_git_repo()

    task =
      create_test_task(%{
        project_id: project.id,
        stage: :review,
        stage_state: :queued,
        worktree_path: worktree
      })

    demo =
      create_test_demo(%{
        task_id: task.id,
        version: 1,
        stale: false,
        head_sha: "previous_commit",
        dirty_digest: "previous_digest"
      })

    assert {:ok, %Task{id: task_id, stage: :review, stage_state: :queued}} =
             Pipeline.refresh_demo_freshness(task)

    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :demo_marked_stale}}

    assert Repo.get!(Demo, demo.id).stale
    assert Repo.get!(Task, task.id).stage == :review
    assert Repo.get!(Task, task.id).stage_state == :queued
  end

  test "marks demo stale but preserves running task state when task is busy" do
    project = create_test_project()
    worktree = create_temp_git_repo()

    task =
      create_test_task(%{
        project_id: project.id,
        stage: :ready_to_merge,
        stage_state: :running,
        worktree_path: worktree
      })

    demo =
      create_test_demo(%{
        task_id: task.id,
        version: 1,
        stale: false,
        head_sha: "different_sha",
        dirty_digest: "different_digest"
      })

    assert {:ok, %Task{stage: :ready_to_merge, stage_state: :running}} =
             Pipeline.refresh_demo_freshness(task)

    assert Repo.get!(Demo, demo.id).stale
  end

  test "enforces authorization" do
    task = create_test_task()

    assert {:error, :not_authorized} =
             Pipeline.refresh_demo_freshness(%Scope{system: false, user: nil}, task)
  end

  test "returns not found for unknown task" do
    assert {:error, :not_found} =
             Pipeline.refresh_demo_freshness("tsk_nonexistent_9999")
  end
end
