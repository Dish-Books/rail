defmodule Rail.Pipeline.Schemas.PlanTest do
  use Rail.DataCase, async: true

  alias Rail.Pipeline.Schemas.Plan
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  test "factory builds a valid plan struct" do
    assert %Plan{
             task_id: "tsk_" <> _id,
             content: "# Implementation Plan" <> _content,
             captured_at: %DateTime{}
           } = Plan.factory()
  end

  test "changeset validates required fields" do
    assert %{
             task_id: ["can't be blank"],
             content: ["can't be blank"],
             captured_at: ["can't be blank"]
           } = errors_on(Plan.changeset(%Plan{}, %{}))
  end

  test "changeset accepts valid attributes" do
    task = create_test_task()
    now = DateTime.utc_now()

    attrs = %{
      content: "# Plan for Task\n\n1. Do X\n2. Do Y",
      captured_at: now
    }

    changeset = Plan.changeset(%Plan{}, attrs, task.id)

    assert changeset.valid?
    assert get_field(changeset, :task_id) == task.id
    assert get_field(changeset, :content) == "# Plan for Task\n\n1. Do X\n2. Do Y"
    assert get_field(changeset, :captured_at) == now
  end

  test "validates foreign key on task_id" do
    now = DateTime.utc_now()

    assert {:error, %{errors: [task_id: {"does not exist", _details}]}} =
             %Plan{}
             |> Plan.changeset(
               %{content: "Content", captured_at: now},
               "tsk_000000000000000000000000"
             )
             |> Repo.insert()
  end

  test "preloads belongs_to task" do
    %Task{id: task_id} = task = create_test_task()

    plan =
      Repo.insert!(
        Plan.changeset(
          %Plan{},
          %{
            content: "Content for preloaded task",
            captured_at: DateTime.utc_now()
          },
          task.id
        )
      )

    preloaded = Repo.preload(plan, :task)

    assert %Plan{task: %Task{id: ^task_id}} = preloaded
  end
end
