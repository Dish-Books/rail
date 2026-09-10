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

  test "loads and attaches latest demo and design to task" do
    scope = Scope.for_system()
    %Task{id: task_id} = task = create_test_task()

    _demo1 = create_test_demo(%{task_id: task.id, version: 1, outcome: "recorded"})
    %{id: demo2_id} = create_test_demo(%{task_id: task.id, version: 2, outcome: "declined"})
    _design1 = create_test_design(%{task_id: task.id, version: 1})
    %{id: design2_id} = create_test_design(%{task_id: task.id, version: 2, picked_key: "dir-2"})

    assert {:ok,
            %Task{
              id: ^task_id,
              demo: %{id: ^demo2_id, version: 2},
              design: %{id: ^design2_id, version: 2}
            }} = Pipeline.get_task(scope, task.id)

    assert %Task{
             id: ^task_id,
             demo: %{id: ^demo2_id, version: 2},
             design: %{id: ^design2_id, version: 2}
           } = Pipeline.get_task!(scope, task.id)
  end

  test "returns nil for demo and design when task has no artifacts" do
    scope = Scope.for_system()
    %Task{id: task_id} = task = create_test_task()

    assert {:ok, %Task{id: ^task_id, demo: nil, design: nil}} = Pipeline.get_task(scope, task.id)
    assert %Task{id: ^task_id, demo: nil, design: nil} = Pipeline.get_task!(scope, task.id)
  end
end
