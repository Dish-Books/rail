defmodule Rail.Pipeline.Actions.StartRebaseTest do
  use Rail.DataCase, async: false

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Users.Schemas.User

  test "refuses to start rebase when task is busy (running or active chat)" do
    project = Repo.insert!(Project.factory())

    task_running =
      Repo.insert!(%{
        Task.factory()
        | project_id: project.id,
          stage: :review,
          stage_state: :running
      })

    assert {:error, :task_busy} = Pipeline.start_rebase(task_running)

    task_chatting =
      Repo.insert!(%{
        Task.factory()
        | project_id: project.id,
          stage: :review,
          stage_state: :awaiting_approval,
          active_chat_role_id: "reviewer"
      })

    assert {:error, :task_busy} = Pipeline.start_rebase(task_chatting)
  end

  test "starts rebase, queues task, preserves stage_state_before_rebase, and broadcasts" do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")
    project = Repo.insert!(Project.factory())
    user = Repo.insert!(User.factory())
    scope = Scope.for_user(user)

    %Task{id: task_id} =
      task =
      Repo.insert!(%{
        Task.factory()
        | project_id: project.id,
          stage: :qa,
          stage_state: :awaiting_approval,
          error: "Some previous error",
          retry_after: DateTime.utc_now()
      })

    assert {:ok,
            %Task{
              is_rebasing: true,
              stage_state_before_rebase: :awaiting_approval,
              stage_state: :queued,
              error: nil,
              retry_after: nil
            }} = Pipeline.start_rebase(scope, task, [])

    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :rebase_started}}
  end

  test "returns error when scope is unauthorized" do
    assert {:error, :not_authorized} = Pipeline.start_rebase(:invalid_scope, "tsk_123")
  end

  test "returns error when task is not found" do
    assert {:error, :not_found} = Pipeline.start_rebase("tsk_nonexistent")
    assert {:error, :not_found} = Pipeline.start_rebase(123)
  end

  test "accepts nil scope and task with opts" do
    project = Repo.insert!(Project.factory())

    task =
      Repo.insert!(%{
        Task.factory()
        | project_id: project.id,
          stage: :qa,
          stage_state: :awaiting_approval
      })

    assert {:ok, %Task{is_rebasing: true}} = Pipeline.start_rebase(nil, task)
    assert {:ok, %Task{is_rebasing: true}} = Pipeline.start_rebase(task.id, dispatcher: :test_dispatcher)
  end
end
