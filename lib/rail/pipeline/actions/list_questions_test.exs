defmodule Rail.Pipeline.Actions.ListQuestionsTest do
  use Rail.DataCase, async: true

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Question

  test "lists questions by project and filters by status" do
    project1 = create_test_project()
    project2 = create_test_project()

    task1 = create_test_task(%{project_id: project1.id})
    task2 = create_test_task(%{project_id: project2.id})

    q1 = create_test_question(%{task_id: task1.id, status: :pending, prompt: "P1 Pending"})
    _q2 = create_test_question(%{task_id: task1.id, status: :answered, prompt: "P1 Answered"})
    _q3 = create_test_question(%{task_id: task2.id, status: :pending, prompt: "P2 Pending"})

    results_all = Pipeline.list_questions(project1.id)
    assert length(results_all) == 2

    results_pending = Pipeline.list_questions(project1, status: :pending)
    assert length(results_pending) == 1
    assert hd(results_pending).id == q1.id

    results_multi_status = Pipeline.list_questions(project1.id, status: [:pending, :answered])
    assert length(results_multi_status) == 2
  end

  test "lists questions by task and supports order_by" do
    task = create_test_task()

    q1 = create_test_question(%{task_id: task.id, prompt: "First", status: :pending})
    q2 = create_test_question(%{task_id: task.id, prompt: "Second", status: :pending})

    desc_order = Pipeline.list_questions(task.id, order_by: [desc: :inserted_at])
    assert Enum.map(desc_order, & &1.id) == [q2.id, q1.id]

    asc_order = Pipeline.list_questions(task, order_by: [asc: :inserted_at])
    assert Enum.map(asc_order, & &1.id) == [q1.id, q2.id]
  end

  test "list_pending_questions convenience functions" do
    project = create_test_project()
    task = create_test_task(%{project_id: project.id})

    q_pending = create_test_question(%{task_id: task.id, status: :pending})
    _q_answered = create_test_question(%{task_id: task.id, status: :answered})

    pending_list = Pipeline.list_pending_questions(project.id)
    assert length(pending_list) == 1
    assert hd(pending_list).id == q_pending.id

    global_pending = Pipeline.list_pending_questions()
    assert Enum.any?(global_pending, &(&1.id == q_pending.id))
  end

  test "scope authorization for list_questions and list_pending_questions" do
    unauth_scope = %Rail.Scope{}
    assert Pipeline.list_questions(unauth_scope, "prj_test") == []
    assert Pipeline.list_pending_questions(unauth_scope, "prj_test") == []

    auth_scope = Rail.Scope.for_system()
    assert [] = Pipeline.list_questions(auth_scope, "prj_test")

    user_scope = %Rail.Scope{user: %{id: "usr_test"}}
    assert [] = Pipeline.list_questions(user_scope, "prj_test")
    assert [] = Pipeline.list_pending_questions(user_scope, "prj_test")
  end

  test "overloaded variants and convenience functions for list_questions and list_pending_questions" do
    user_scope = %Rail.Scope{user: %{id: "usr_test"}}
    assert [] = Pipeline.list_questions(user_scope, status: :pending)
    assert [] = Pipeline.list_questions(user_scope, "prj_test")
    assert [] = Pipeline.list_pending_questions(user_scope, status: :pending)
    assert [] = Pipeline.list_pending_questions(user_scope, "prj_test")

    assert [] = Pipeline.list_questions("prj_test")
    assert [] = Pipeline.list_questions("tsk_test")
    assert [] = Pipeline.list_questions()
    assert [] = Pipeline.list_pending_questions("prj_test")
    assert [] = Pipeline.list_pending_questions("prj_test", order_by: [asc: :inserted_at])
    assert [] = Pipeline.list_pending_questions()
  end

  test "get_question and get_question!" do
    %Question{id: expected_id} = create_test_question()
    user_scope = %Rail.Scope{user: %{id: "usr_test"}}

    assert {:ok, %Question{id: ^expected_id}} = Pipeline.get_question(expected_id)
    assert %Question{id: ^expected_id} = Pipeline.get_question!(expected_id)

    assert {:ok, %Question{id: ^expected_id}} = Pipeline.get_question(user_scope, expected_id)
    assert %Question{id: ^expected_id} = Pipeline.get_question!(user_scope, expected_id)

    assert {:error, :not_found} = Pipeline.get_question("qst_nonexistent")
    assert {:error, :not_authorized} = Pipeline.get_question(%Rail.Scope{}, expected_id)

    assert_raise Ecto.NoResultsError, fn ->
      Pipeline.get_question!("qst_nonexistent")
    end

    assert_raise Ecto.NoResultsError, fn ->
      Pipeline.get_question!(%Rail.Scope{}, expected_id)
    end
  end

  test "supports preload option" do
    %Rail.Pipeline.Schemas.Task{id: expected_task_id} = create_test_task()
    %Question{id: q_id} = create_test_question(%{task_id: expected_task_id})

    assert [%Question{id: ^q_id, task: %Rail.Pipeline.Schemas.Task{id: ^expected_task_id}}] =
             Pipeline.list_questions(expected_task_id, preload: [:task])
  end
end
