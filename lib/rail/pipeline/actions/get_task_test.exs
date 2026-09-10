defmodule Rail.Pipeline.Actions.GetTaskTest do
  use Rail.DataCase, async: true

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Scope

  test "returns task for authenticated user scope" do
    scope = Scope.for_user(%{admin: false})
    %Task{id: task_id} = task = create_test_task()

    assert {:ok, %Task{id: ^task_id}} = Pipeline.get_task(scope, task.id)
  end

  test "returns task for system scope" do
    scope = Scope.for_system()
    %Task{id: task_id} = task = create_test_task()

    assert {:ok, %Task{id: ^task_id}} = Pipeline.get_task(scope, task.id)
  end

  test "returns not found error when task does not exist" do
    scope = Scope.for_system()
    assert {:error, :not_found} = Pipeline.get_task(scope, "tsk_000000000000000000000000")
  end

  test "returns not authorized error for nil or invalid scope" do
    task = create_test_task()
    assert {:error, :not_authorized} = Pipeline.get_task(nil, task.id)
    assert {:error, :not_authorized} = Pipeline.get_task(%Scope{user: nil, system: false}, task.id)
  end

  test "get_task! returns task for system scope" do
    scope = Scope.for_system()
    %Task{id: task_id} = task = create_test_task()

    assert %Task{id: ^task_id} = Pipeline.get_task!(scope, task.id)
  end

  test "get_task! returns task for user scope" do
    scope = Scope.for_user(%{admin: false})
    %Task{id: task_id} = task = create_test_task()

    assert %Task{id: ^task_id} = Pipeline.get_task!(scope, task.id)
  end

  test "get_task! raises Ecto.NoResultsError when task does not exist" do
    scope = Scope.for_system()

    assert_raise Ecto.NoResultsError, fn ->
      Pipeline.get_task!(scope, "tsk_000000000000000000000000")
    end
  end

  test "get_task! raises Ecto.NoResultsError when scope is unauthorized" do
    task = create_test_task()

    assert_raise Ecto.NoResultsError, fn ->
      Pipeline.get_task!(nil, task.id)
    end
  end
end
