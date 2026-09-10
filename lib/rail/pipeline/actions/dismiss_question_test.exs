defmodule Rail.Pipeline.Actions.DismissQuestionTest do
  use Rail.DataCase, async: true

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Task

  test "dismisses a pending question and releases blocked task" do
    project = create_test_project()
    task = create_test_task(%{project_id: project.id, stage_state: :blocked})
    q = create_test_question(%{task_id: task.id, status: :pending})
    {:ok, task} = task |> Task.changeset(%{question_id: q.id}) |> Repo.update()

    assert {:ok, %Question{status: :dismissed}} = Pipeline.dismiss_question(q.id)

    reloaded_q = Repo.get!(Question, q.id)
    assert reloaded_q.status == :dismissed

    reloaded_task = Repo.get!(Task, task.id)
    assert reloaded_task.stage_state == :awaiting_approval
    assert is_nil(reloaded_task.question_id)
  end

  test "dismisses question without touching task if task was not parked on it" do
    project = create_test_project()
    task = create_test_task(%{project_id: project.id, stage_state: :running, question_id: nil})
    q = create_test_question(%{task_id: task.id, status: :pending})

    assert {:ok, %Question{status: :dismissed}} = Pipeline.dismiss_question(q)

    reloaded_task = Repo.get!(Task, task.id)
    assert reloaded_task.stage_state == :running
    assert is_nil(reloaded_task.question_id)
  end

  test "returns error when dismissing already resolved question" do
    q_answered = create_test_question(%{status: :answered})
    assert {:error, :already_resolved} = Pipeline.dismiss_question(q_answered.id)

    q_dismissed = create_test_question(%{status: :dismissed})
    assert {:error, :already_resolved} = Pipeline.dismiss_question(q_dismissed.id)
  end

  test "validates scope authorization and existence" do
    assert {:error, :not_authorized} = Pipeline.dismiss_question(%Rail.Scope{}, "qst_any")
    assert {:error, :not_found} = Pipeline.dismiss_question("qst_nonexistent")
    assert {:error, :not_found} = Pipeline.dismiss_question(123)

    q = create_test_question(%{status: :pending})
    user_scope = %Rail.Scope{user: %{id: "usr_test"}}
    assert {:ok, %Question{status: :dismissed}} = Pipeline.dismiss_question(user_scope, q.id)
  end
end
