defmodule Rail.Pipeline.Actions.RegisterQuestionTest do
  use Rail.DataCase, async: true

  import Rail.Pipeline.Utils.DetectQuestions
  import Rail.Pipeline.Utils.QuestionQueue

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.DetectedQuestion
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Roles

  setup %{project: project} do
    roles =
      Map.new([:product, :design, :architect, :engineer, :review, :qa, :demo], fn stage ->
        {:ok, role} = Roles.get_role(project_id: project.id, stage: stage)

        {stage, role}
      end)

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{
              "id" => "lin_register_question_1",
              "identifier" => "RGQ-1",
              "title" => "Register Question Issue"
            }
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Register Question Issue"})

    {:ok, task} = Pipeline.create_task(issue, :product)

    %{project: project, issue: issue, task: task, roles: roles}
  end

  test "registers a detected question struct and blocks task and run", %{task: task, roles: roles} do
    role = roles[:engineer]

    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(task, %{
        stage: :engineer
      })

    task_title = Repo.get!(Issue, task.issue_id).title

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task_id,
        role_id: role.id,
        status: :running,
        started_at: DateTime.utc_now()
      })

    run = Repo.preload(run, task: :issue)

    detector = %DetectedQuestion{
      prompt: "Use Postgres or SQLite?",
      options: ["Postgres", "SQLite"],
      context_summary: "Asked during: #{task_title}"
    }

    assert {:ok,
            %Question{
              id: q_id,
              prompt: "Use Postgres or SQLite?",
              options: ["Postgres", "SQLite"],
              status: :pending
            }} = Pipeline.register_question(run, detector)

    assert %Task{} = Repo.get!(Task, task_id)
    assert Enum.map(pending_questions(task_id), & &1.id) == [q_id]
    assert %Run{status: :blocked_on_input} = Repo.get!(Run, run.id)
  end

  test "registers question using raw string with marker", %{task: task, roles: roles} do
    role = roles[:engineer]

    {:ok, task} =
      Pipeline.update_task(task, %{
        stage: :engineer
      })

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :running,
        started_at: DateTime.utc_now()
      })

    run = Repo.preload(run, task: :issue)

    [detected] = detect_questions("[QUESTION: Which cache backend?] [OPTIONS: Redis, ETS]")

    assert {:ok, %Question{prompt: "Which cache backend?", options: ["Redis", "ETS"]}} =
             Pipeline.register_question(run, detected)
  end

  test "belongs to the run that asked", %{task: task, roles: roles} do
    {:ok, task} =
      Pipeline.update_task(task, %{
        stage: :engineer
      })

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:engineer].id,
        status: :running,
        started_at: DateTime.utc_now()
      })

    %Run{id: expected_run_id} = run = Repo.preload(run, task: :issue)

    question = %DetectedQuestion{
      prompt: "Which cache eviction policy?",
      options: ["Yes", "No"],
      context_summary: "Context details"
    }

    assert {:ok, %Question{prompt: "Which cache eviction policy?", options: ["Yes", "No"], run_id: ^expected_run_id}} =
             Pipeline.register_question(run, question)

    assert %Task{} = Repo.get!(Task, task.id)
  end

  test "files the question even when a reply is already queued on the run", %{task: task, roles: roles} do
    role = roles[:engineer]

    {:ok, task} =
      Pipeline.update_task(task, %{
        stage: :engineer
      })

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :running,
        started_at: DateTime.utc_now(),
        pending_answer: "Previous queued answer from human"
      })

    run = Repo.preload(run, task: :issue)

    detector = %DetectedQuestion{prompt: "Should I proceed anyway?", options: []}

    assert {:ok, %Question{id: question_id}} = Pipeline.register_question(run, detector)

    assert %Task{} = Repo.get!(Task, task.id)
    assert Enum.map(pending_questions(task.id), & &1.id) == [question_id]
    assert %Run{status: :blocked_on_input, pending_answer: "Previous queued answer from human"} = Repo.get!(Run, run.id)
  end

  test "duplicate suppression: reuses existing pending question with case-insensitively identical prompt", %{
    task: task,
    roles: roles
  } do
    role = roles[:engineer]

    {:ok, task} =
      Pipeline.update_task(task, %{
        stage: :engineer
      })

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :running,
        started_at: DateTime.utc_now()
      })

    run = Repo.preload(run, task: :issue)

    {:ok, %Question{id: existing_id}} =
      Pipeline.register_question(run, %DetectedQuestion{
        prompt: "Should we use PostgreSQL?"
      })

    # Incoming question has different casing and extra spaces
    detector = %DetectedQuestion{prompt: "  should we use postgresql?  ", options: []}

    assert {:ok, %Question{id: ^existing_id}} = Pipeline.register_question(run, detector)

    assert %Task{} = Repo.get!(Task, task.id)
    assert Enum.map(pending_questions(task.id), & &1.id) == [existing_id]
  end

  test "a second question queues behind the one the task is parked on", %{
    task: task,
    roles: roles
  } do
    role = roles[:engineer]

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :running,
        started_at: DateTime.utc_now()
      })

    run = Repo.preload(run, task: :issue)

    {:ok, %Question{id: first_id}} =
      Pipeline.register_question(run, %DetectedQuestion{
        prompt: "Question prompt 7909?"
      })

    {:ok, task} = Pipeline.update_task(task, %{})

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :blocked_on_input,
        started_at: DateTime.utc_now()
      })

    run = Repo.preload(run, task: :issue)

    detector = %DetectedQuestion{prompt: "Second question in same run?", options: []}

    assert {:ok, %Question{id: second_id}} = Pipeline.register_question(run, detector)

    # The second question queues behind the first: the human keeps answering the one
    # already in front, and the stage stays parked.
    assert %Task{} = Repo.get!(Task, task.id)

    assert Enum.map(pending_questions(task.id), & &1.id) == [first_id, second_id]
  end

  test "rejects a blank prompt", %{task: task, roles: roles} do
    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:engineer].id,
        status: :running,
        started_at: DateTime.utc_now()
      })

    run = Repo.preload(run, task: :issue)

    assert {:error, :invalid_prompt} = Pipeline.register_question(run, %DetectedQuestion{prompt: "   "})
  end
end
