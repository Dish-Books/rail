defmodule Rail.Pipeline.Actions.AnswerQuestionTest do
  use Rail.DataCase, async: true

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Runs
  alias Rail.Runs.Schemas.RoleRun
  alias Rail.Runs.Schemas.Run

  test "answers a question, clears task.question_id, and queues stage with formatted pending_answer" do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")

    project = create_test_project()
    role = create_test_role(%{project_id: project.id, stage: :engineer})
    %Task{id: task_id} = create_test_task(%{project_id: project.id, stage: :engineer, stage_state: :blocked})
    role_run = create_test_role_run(%{task_id: task_id, role_id: role.id, status: :blocked_on_input})

    q =
      create_test_question(%{
        task_id: task_id,
        role_id: role.id,
        prompt: "Use Postgres or MySQL?",
        status: :pending
      })

    task = Repo.get!(Task, task_id)
    {:ok, _task} = task |> Task.changeset(%{question_id: q.id}) |> Repo.update()

    assert {:ok, %Question{status: :answered, answer: "Use Postgres"}} =
             Pipeline.answer_question(q.id, "Use Postgres")

    assert %Question{status: :answered, answer: "Use Postgres", answered_at: %DateTime{}} =
             Repo.get!(Question, q.id)

    assert %Task{stage_state: :queued, question_id: nil, error: nil} = Repo.get!(Task, task_id)

    expected_pending = "You asked: Use Postgres or MySQL?\nThe answer is: Use Postgres"
    assert %RoleRun{auto_retries: 0, pending_answer: ^expected_pending} = Repo.get!(RoleRun, role_run.id)

    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :changes_requested}}
  end

  test "appends with newline separator if role_run already had pending_answer" do
    project = create_test_project()
    role = create_test_role(%{project_id: project.id, stage: :engineer})
    task = create_test_task(%{project_id: project.id, stage: :engineer, stage_state: :blocked})

    role_run =
      create_test_role_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :blocked_on_input,
        pending_answer: "Initial instructions"
      })

    q =
      create_test_question(%{
        task_id: task.id,
        role_id: role.id,
        prompt: "Port number?",
        status: :pending
      })

    {:ok, _task} = task |> Task.changeset(%{question_id: q.id}) |> Repo.update()

    assert {:ok, %Question{status: :answered}} = Pipeline.answer_question(q.id, "4000")

    expected_pending = "Initial instructions\n\nYou asked: Port number?\nThe answer is: 4000"
    assert %RoleRun{pending_answer: ^expected_pending} = Repo.get!(RoleRun, role_run.id)
  end

  test "stops live running process if task is running and not rebasing" do
    project = create_test_project()
    role = create_test_role(%{project_id: project.id, stage: :engineer})
    task = create_test_task(%{project_id: project.id, stage: :engineer, stage_state: :blocked, is_rebasing: false})
    role_run = create_test_role_run(%{task_id: task.id, role_id: role.id, status: :blocked_on_input})

    q =
      create_test_question(%{
        task_id: task.id,
        role_id: role.id,
        prompt: "Run tests?",
        status: :pending
      })

    {:ok, task} = task |> Task.changeset(%{question_id: q.id}) |> Repo.update()

    # Create a live running Run row
    run =
      Repo.insert!(%Run{
        role_run_id: role_run.id,
        task_id: task.id,
        kind: :stage,
        status: :running,
        stream_path: "/tmp/fake_stream_ans",
        node: "node_test",
        boot_id: "boot_test",
        started_at: DateTime.utc_now()
      })

    assert Runs.is_running?(task.id)

    assert {:ok, %Question{status: :answered}} = Pipeline.answer_question(q.id, "Yes, run all tests")

    reloaded_run = Repo.get!(Run, run.id)
    assert reloaded_run.status == :finished
    refute Runs.is_running?(task.id)
  end

  test "does not stop live process if task is currently rebasing" do
    project = create_test_project()
    role = create_test_role(%{project_id: project.id, stage: :engineer})
    task = create_test_task(%{project_id: project.id, stage: :engineer, stage_state: :blocked, is_rebasing: true})
    role_run = create_test_role_run(%{task_id: task.id, role_id: role.id, status: :blocked_on_input})

    q =
      create_test_question(%{
        task_id: task.id,
        role_id: role.id,
        prompt: "Rebase onto main?",
        status: :pending
      })

    {:ok, task} = task |> Task.changeset(%{question_id: q.id}) |> Repo.update()

    run =
      Repo.insert!(%Run{
        role_run_id: role_run.id,
        task_id: task.id,
        kind: :stage,
        status: :running,
        stream_path: "/tmp/fake_rebase_stream",
        node: "node_test",
        boot_id: "boot_test",
        started_at: DateTime.utc_now()
      })

    assert Runs.is_running?(task.id)

    assert {:ok, %Question{status: :answered}} = Pipeline.answer_question(q.id, "Yes")

    # Run was not terminated because task is rebasing
    reloaded_run = Repo.get!(Run, run.id)
    assert reloaded_run.status == :running
  end

  test "validates empty answer, already resolved, and missing questions" do
    project = create_test_project()
    role = create_test_role(%{project_id: project.id, stage: :engineer})
    task = create_test_task(%{project_id: project.id, stage: :engineer, stage_state: :blocked})
    _role_run = create_test_role_run(%{task_id: task.id, role_id: role.id, status: :blocked_on_input})

    q = create_test_question(%{task_id: task.id, status: :pending})

    assert {:error, :empty_answer} = Pipeline.answer_question(q.id, "")
    assert {:error, :empty_answer} = Pipeline.answer_question(q.id, "   ")
    assert {:error, :empty_answer} = Pipeline.answer_question(q.id, nil)

    # Calling with Question struct directly and with user scope
    user_scope = %Rail.Scope{user: %{id: "usr_test"}}
    assert {:ok, %Question{status: :answered}} = Pipeline.answer_question(user_scope, q, "Good answer")

    # Already resolved
    assert {:error, :already_resolved} = Pipeline.answer_question(q.id, "New answer")

    # Missing question and invalid identifier
    assert {:error, :not_found} = Pipeline.answer_question("qst_nonexistent", "Answer")
    assert {:error, :not_found} = Pipeline.answer_question(123, "Answer")
    assert {:error, :not_authorized} = Pipeline.answer_question(%Rail.Scope{}, q.id, "Answer")

    # Missing task behind question
    q_no_task = %{q | task_id: "tsk_missing"}
    assert {:error, :task_not_found} = Pipeline.answer_question(q_no_task, "Answer")

    # Error propagation from request_changes (e.g. no role for stage)
    project_no_role = create_test_project()
    task_no_role = create_test_task(%{project_id: project_no_role.id, stage: :engineer, stage_state: :blocked})
    q_no_role = create_test_question(%{task_id: task_no_role.id, status: :pending})
    assert {:error, {:no_role_for_stage, :engineer}} = Pipeline.answer_question(q_no_role, "Answer")
  end
end
