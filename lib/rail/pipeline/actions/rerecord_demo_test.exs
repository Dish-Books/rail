defmodule Rail.Pipeline.Actions.RerecordDemoTest do
  use Rail.DataCase, async: false

  alias Rail.Artifacts.Schemas.Demo
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Scope

  test "marks latest demo stale, resets task to demo queued, broadcasts and pumps dispatcher" do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")
    project = create_test_project()
    worktree = create_temp_scratch_dir()

    task =
      create_test_task(%{
        project_id: project.id,
        stage: :ready_to_merge,
        stage_state: :awaiting_approval,
        worktree_path: worktree,
        error: "Previous failure"
      })

    demo =
      create_test_demo(%{
        task_id: task.id,
        version: 1,
        stale: false
      })

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

  test "rerecord_demo succeeds even when no previous demo exists" do
    project = create_test_project()
    worktree = create_temp_scratch_dir()

    task =
      create_test_task(%{
        project_id: project.id,
        stage: :demo,
        stage_state: :failed,
        worktree_path: worktree,
        error: "Recording failed"
      })

    assert {:ok, %Task{stage: :demo, stage_state: :queued, error: nil}} =
             Pipeline.rerecord_demo(Scope.user_scope(), task.id, [])

    assert {:error, :not_found} = Pipeline.rerecord_demo(Scope.for_system(), :bad_id, [])
  end

  test "guards against merged tasks" do
    project = create_test_project()
    worktree = create_temp_scratch_dir()

    task_merged_stage =
      create_test_task(%{
        project_id: project.id,
        stage: :merged,
        stage_state: :awaiting_approval,
        worktree_path: worktree
      })

    task_merged_at =
      create_test_task(%{
        project_id: project.id,
        stage: :ready_to_merge,
        stage_state: :awaiting_approval,
        worktree_path: worktree,
        merged_at: DateTime.utc_now()
      })

    assert {:error, :task_merged} = Pipeline.rerecord_demo(task_merged_stage)
    assert {:error, :task_merged} = Pipeline.rerecord_demo(task_merged_at)
  end

  test "guards against missing worktree directory on disk" do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")
    project = create_test_project()
    nonexistent_path = "/tmp/nonexistent_worktree_#{System.unique_integer([:positive])}"

    task =
      create_test_task(%{
        project_id: project.id,
        stage: :ready_to_merge,
        stage_state: :awaiting_approval,
        worktree_path: nonexistent_path
      })

    assert {:error, :no_worktree} = Pipeline.rerecord_demo(task)

    assert_receive {:pipeline_changed, %{task_id: task_id, event: :rerecord_demo_failed}}
    assert task_id == task.id

    reloaded = Repo.get!(Task, task.id)
    assert reloaded.error == "Worktree does not exist on disk (#{nonexistent_path})."

    task_nil_worktree =
      create_test_task(%{
        project_id: project.id,
        stage: :ready_to_merge,
        stage_state: :awaiting_approval,
        worktree_path: nil
      })

    assert {:error, :no_worktree} = Pipeline.rerecord_demo(task_nil_worktree)
    reloaded_nil = Repo.get!(Task, task_nil_worktree.id)
    assert reloaded_nil.error == "Worktree does not exist on disk ()."
  end

  test "can_rerecord_demo? checks eligibility accurately" do
    project = create_test_project()
    worktree = create_temp_scratch_dir()

    eligible_ready =
      create_test_task(%{
        project_id: project.id,
        stage: :ready_to_merge,
        stage_state: :awaiting_approval,
        worktree_path: worktree
      })

    eligible_demo_failed =
      create_test_task(%{
        project_id: project.id,
        stage: :demo,
        stage_state: :failed,
        worktree_path: worktree
      })

    busy_task =
      create_test_task(%{
        project_id: project.id,
        stage: :ready_to_merge,
        stage_state: :running,
        worktree_path: worktree
      })

    merged_task =
      create_test_task(%{
        project_id: project.id,
        stage: :merged,
        stage_state: :awaiting_approval,
        worktree_path: worktree
      })

    missing_path_task =
      create_test_task(%{
        project_id: project.id,
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

  test "enforces authorization" do
    task = create_test_task()

    assert {:error, :not_authorized} =
             Pipeline.rerecord_demo(%Scope{system: false, user: nil}, task)
  end

  test "returns not found for unknown task" do
    assert {:error, :not_found} =
             Pipeline.rerecord_demo("tsk_nonexistent_9999")
  end
end
