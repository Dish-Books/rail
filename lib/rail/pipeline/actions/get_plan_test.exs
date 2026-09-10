defmodule Rail.Pipeline.Actions.GetPlanTest do
  use Rail.DataCase, async: true

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Plan
  alias Rail.Scope

  test "returns latest plan for system scope and user scope" do
    task = create_test_task()
    sys_scope = Scope.for_system()
    user_scope = Scope.for_user(%{admin: false})

    t1 = DateTime.shift(DateTime.utc_now(), second: -10)
    t2 = DateTime.utc_now()

    _older_plan = create_test_plan(%{task_id: task.id, content: "# Old Plan", captured_at: t1})
    %Plan{id: expected_plan_id} = create_test_plan(%{task_id: task.id, content: "# New Plan", captured_at: t2})

    assert {:ok, %Plan{id: ^expected_plan_id, content: "# New Plan"}} = Pipeline.get_plan(sys_scope, task.id)

    assert {:ok, %Plan{id: ^expected_plan_id}} = Pipeline.get_plan(user_scope, task)
    assert {:ok, %Plan{id: ^expected_plan_id}} = Pipeline.get_plan(task.id)
    assert {:ok, %Plan{id: ^expected_plan_id}} = Pipeline.get_plan(task)
  end

  test "returns not found error when plan does not exist" do
    task = create_test_task()
    sys_scope = Scope.for_system()

    assert {:error, :not_found} = Pipeline.get_plan(sys_scope, task.id)
    assert {:error, :not_found} = Pipeline.get_plan(sys_scope, "tsk_nonexistent")
    assert {:error, :not_found} = Pipeline.get_plan(12_345)
  end

  test "returns not authorized error for invalid scope" do
    task = create_test_task()
    assert {:error, :not_authorized} = Pipeline.get_plan(nil, task.id)
    assert {:error, :not_authorized} = Pipeline.get_plan(%Scope{user: nil, system: false}, task.id)
  end
end
