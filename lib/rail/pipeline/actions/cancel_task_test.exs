defmodule Rail.Pipeline.Actions.CancelTaskTest do
  use Rail.DataCase, async: false

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Users.Schemas.User

  test "cancels a running task, sets failed state and error, and broadcasts" do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")
    project = Repo.insert!(Project.factory())
    user = Repo.insert!(User.factory())
    scope = Scope.for_user(user)

    %Task{id: task_id} =
      task =
      Repo.insert!(%{
        Task.factory()
        | project_id: project.id,
          stage: :engineer,
          stage_state: :running,
          retry_after: DateTime.utc_now()
      })

    assert {:ok,
            %Task{
              stage_state: :failed,
              error: "Cancelled.",
              retry_after: nil
            }} = Pipeline.cancel_task(scope, task)

    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :task_cancelled}}
  end

  test "cancelling a rebasing task restores pre-rebase state with conflict error" do
    project = Repo.insert!(Project.factory())

    task =
      Repo.insert!(%{
        Task.factory()
        | project_id: project.id,
          stage: :ready_to_merge,
          stage_state: :queued,
          is_rebasing: true,
          stage_state_before_rebase: :awaiting_approval
      })

    assert {:ok,
            %Task{
              is_rebasing: false,
              stage_state: :awaiting_approval,
              stage_state_before_rebase: nil,
              error: "Rebase cancelled. The branch still conflicts."
            }} = Pipeline.cancel_task(task.id)
  end

  test "cancelling a task with active chat turn stops chat" do
    project = Repo.insert!(Project.factory())

    task =
      Repo.insert!(%{
        Task.factory()
        | project_id: project.id,
          stage: :engineer,
          stage_state: :running,
          active_chat_role_id: "engineer"
      })

    assert {:ok,
            %Task{
              active_chat_role_id: nil,
              stage_state: :failed,
              error: "Cancelled."
            }} = Pipeline.cancel_task(task)
  end

  test "returns error when scope is not authorized" do
    assert {:error, :not_authorized} = Pipeline.cancel_task(:invalid_scope, "tsk_123")
  end

  test "returns error when task is not found" do
    assert {:error, :not_found} = Pipeline.cancel_task("tsk_nonexistent_999")
    assert {:error, :not_found} = Pipeline.cancel_task(Scope.for_system(), 12_345)
  end

  test "cancels with options and delegates properly" do
    project = Repo.insert!(Project.factory())
    task = Repo.insert!(%{Task.factory() | project_id: project.id})

    assert {:ok, %Task{stage_state: :failed}} =
             Pipeline.cancel_task(task, dispatcher: nil)

    task2 = Repo.insert!(%{Task.factory() | project_id: project.id})

    assert {:ok, %Task{stage_state: :failed}} =
             Pipeline.cancel_task(Scope.for_system(), task2, dispatcher: nil)
  end
end
