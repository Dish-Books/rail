defmodule Rail.Pipeline.Actions.RegisterQuestionTest do
  use Rail.DataCase, async: true

  import Ecto.Query

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Runs.QuestionDetector
  alias Rail.Runs.Schemas.RoleRun
  alias Rail.Runs.Schemas.RunEvent

  test "registers a detected question struct and blocks task and role run" do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")

    project = create_test_project()
    role = create_test_role(%{project_id: project.id, stage: :engineer})

    %Task{id: task_id, title: task_title} =
      create_test_task(%{project_id: project.id, stage: :engineer, stage_state: :running})

    role_run = create_test_role_run(%{task_id: task_id, role_id: role.id, status: :running})

    detector = %QuestionDetector{
      prompt: "Use Postgres or SQLite?",
      options: ["Postgres", "SQLite"],
      task_id: task_id,
      role_id: role.id,
      context_summary: "Asked during: #{task_title}"
    }

    assert {:ok,
            %Question{
              id: q_id,
              prompt: "Use Postgres or SQLite?",
              options: ["Postgres", "SQLite"],
              status: :pending
            }} = Pipeline.register_question(task_id, role_run.id, detector)

    assert %Task{stage_state: :blocked, question_id: ^q_id} = Repo.get!(Task, task_id)
    assert %RoleRun{status: :blocked_on_input} = Repo.get!(RoleRun, role_run.id)

    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :question_registered}}
  end

  test "registers question using raw string with marker" do
    project = create_test_project()
    role = create_test_role(%{project_id: project.id, stage: :engineer})
    task = create_test_task(%{project_id: project.id, stage: :engineer, stage_state: :running})
    role_run = create_test_role_run(%{task_id: task.id, role_id: role.id, status: :running})

    raw_text = "[QUESTION: Which cache backend?] [OPTIONS: Redis, ETS]"

    assert {:ok, %Question{prompt: "Which cache backend?", options: ["Redis", "ETS"]}} =
             Pipeline.register_question(task, role_run, raw_text)
  end

  test "registers question using map attributes and resolves role when role_run is nil" do
    project = create_test_project()
    _role = create_test_role(%{project_id: project.id, stage: :engineer})
    task = create_test_task(%{project_id: project.id, stage: :engineer, stage_state: :running})

    map_attrs = %{
      prompt: "Map prompt question?",
      options: ["Yes", "No"],
      context_summary: "Context details"
    }

    assert {:ok, %Question{prompt: "Map prompt question?", options: ["Yes", "No"]}} =
             Pipeline.register_question(task, map_attrs)

    reloaded = Repo.get!(Task, task.id)
    assert reloaded.stage_state == :blocked
  end

  test "duplicate suppression: drops question if role_run has pending_answer" do
    Phoenix.PubSub.subscribe(Rail.PubSub, "run:test_role_run")

    project = create_test_project()
    role = create_test_role(%{project_id: project.id, stage: :engineer})
    task = create_test_task(%{project_id: project.id, stage: :engineer, stage_state: :running})

    role_run =
      create_test_role_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :running,
        pending_answer: "Previous queued answer from human"
      })

    detector = %QuestionDetector{prompt: "Should I proceed anyway?", options: []}

    assert {:ok, :dropped} = Pipeline.register_question(task.id, role_run.id, detector)

    # Task is NOT blocked
    reloaded_task = Repo.get!(Task, task.id)
    assert reloaded_task.stage_state == :running
    assert is_nil(reloaded_task.question_id)

    # Run event recorded
    events = Repo.all(from e in RunEvent, where: e.role_run_id == ^role_run.id)
    assert length(events) == 1
    assert hd(events).line =~ "Question asked before the human reply reached this role"
  end

  test "duplicate suppression: reuses existing pending question with case-insensitively identical prompt" do
    project = create_test_project()
    role = create_test_role(%{project_id: project.id, stage: :engineer})
    task = create_test_task(%{project_id: project.id, stage: :engineer, stage_state: :running})
    role_run = create_test_role_run(%{task_id: task.id, role_id: role.id, status: :running})

    %Question{id: existing_id} =
      create_test_question(%{
        task_id: task.id,
        role_id: role.id,
        prompt: "Should we use PostgreSQL?",
        status: :pending
      })

    # Incoming question has different casing and extra spaces
    detector = %QuestionDetector{prompt: "  should we use postgresql?  ", options: []}

    assert {:ok, %Question{id: ^existing_id}} = Pipeline.register_question(task, role_run, detector)

    assert %Task{stage_state: :blocked, question_id: ^existing_id} = Repo.get!(Task, task.id)
  end

  test "single-question-per-run limit: ignores question if task is already blocked on a question" do
    project = create_test_project()
    role = create_test_role(%{project_id: project.id, stage: :engineer})
    q = create_test_question(%{status: :pending})
    task = create_test_task(%{project_id: project.id, stage_state: :blocked, question_id: q.id})
    role_run = create_test_role_run(%{task_id: task.id, role_id: role.id, status: :blocked_on_input})

    detector = %QuestionDetector{prompt: "Second question in same run?", options: []}

    assert {:ok, :already_registered} = Pipeline.register_question(task, role_run, detector)
    assert Repo.get!(Task, task.id).question_id == q.id
  end

  test "error cases: not found, invalid prompt, no question detected" do
    assert {:error, :task_not_found} = Pipeline.register_question("tsk_missing", %{prompt: "Q?"})
    assert {:error, :task_not_found} = Pipeline.register_question(123, %{prompt: "Q?"})

    # Task without a role resolves role_id to nil
    project = create_test_project()
    task_no_role = create_test_task(%{project_id: project.id, stage: :design})
    assert {:ok, %Question{prompt: "Q?"}} = Pipeline.register_question(task_no_role, %{prompt: "Q?"}, [])

    task = create_test_task()
    assert {:error, :invalid_prompt} = Pipeline.register_question(task, %{prompt: "   "})
    assert {:error, :no_question_detected} = Pipeline.register_question(task, "Just some prose text")
    assert {:error, :invalid_question_attrs} = Pipeline.register_question(task, 12_345)
  end
end
