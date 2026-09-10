defmodule Rail.Pipeline.Actions.DeclineDemoTest do
  use Rail.DataCase, async: false

  alias Rail.Artifacts.Schemas.Demo
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Scope

  test "declines demo with default note, creates demo record, and advances to ready_to_merge" do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")
    project = create_test_project()

    task =
      create_test_task(%{
        project_id: project.id,
        stage: :demo,
        stage_state: :queued,
        error: "Previous error"
      })

    assert {:ok,
            %Task{
              id: task_id,
              stage: :ready_to_merge,
              stage_state: :awaiting_approval,
              error: nil,
              retry_after: nil
            }} = Pipeline.decline_demo(task)

    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :demo_declined}}

    assert %Demo{
             task_id: ^task_id,
             version: 1,
             outcome: "declined",
             note: "Declined by human",
             stale: false,
             segments: []
           } = Repo.one(from d in Demo, where: d.task_id == ^task_id)
  end

  test "declines demo with custom note and increments version on subsequent demo" do
    project = create_test_project()

    task =
      create_test_task(%{
        project_id: project.id,
        stage: :demo,
        stage_state: :queued
      })

    create_test_demo(%{
      task_id: task.id,
      version: 1,
      outcome: "recorded",
      note: "Initial run"
    })

    assert {:ok, %Task{stage: :ready_to_merge, stage_state: :awaiting_approval}} =
             Pipeline.decline_demo(Scope.for_system(), task.id, "Non-UI refactor, CLI verified")

    latest_demo =
      Repo.one(
        from d in Demo,
          where: d.task_id == ^task.id,
          order_by: [desc: d.version],
          limit: 1
      )

    assert %Demo{
             version: 2,
             outcome: "declined",
             note: "Non-UI refactor, CLI verified"
           } = latest_demo
  end

  test "declines demo and records fingerprint when worktree is on disk" do
    project = create_test_project()
    worktree = create_temp_git_repo()

    task =
      create_test_task(%{
        project_id: project.id,
        stage: :demo,
        stage_state: :queued,
        worktree_path: worktree
      })

    assert {:ok, %Task{stage: :ready_to_merge, stage_state: :awaiting_approval}} =
             Pipeline.decline_demo(task, "No demo needed")

    assert %Demo{
             head_sha: head_sha,
             dirty_digest: dirty_digest,
             outcome: "declined"
           } = Repo.one(from d in Demo, where: d.task_id == ^task.id)

    assert is_binary(head_sha) and head_sha != ""
    assert is_binary(dirty_digest) and dirty_digest != ""
  end

  test "enforces authorization" do
    task = create_test_task()

    assert {:error, :not_authorized} =
             Pipeline.decline_demo(%Scope{system: false, user: nil}, task, "Note")

    assert {:ok, %Task{}} =
             Pipeline.decline_demo(Scope.user_scope(), task, "Note")
  end

  test "returns not found for unknown task" do
    assert {:error, :not_found} =
             Pipeline.decline_demo("tsk_nonexistent_9999", "Note")

    assert {:error, :not_found} =
             Pipeline.decline_demo(:bad_id, "Note")
  end

  test "declines demo when worktree path is a non-git directory" do
    project = create_test_project()
    scratch_worktree = create_temp_scratch_dir()

    task =
      create_test_task(%{
        project_id: project.id,
        stage: :demo,
        stage_state: :queued,
        worktree_path: scratch_worktree
      })

    assert {:ok, %Task{stage: :ready_to_merge}} = Pipeline.decline_demo(task, "Non-git worktree")
  end
end
