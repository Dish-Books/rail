defmodule Rail.Pipeline.Actions.RegisterQuestionTest do
  use Rail.DataCase, async: true

  import Rail.Pipeline.Utils.QuestionQueue

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Runs
  alias Rail.Runs.DetectedQuestion
  alias Rail.Runs.Schemas.Run
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    {:ok, backend} =
      Rail.Backends.create_backend(system_scope(), %{name: :claude, executable_path: "/usr/bin/true"})

    scope = system_scope()

    {:ok, workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Register Question Workspace",
        external_id: "lin_ws_register_question",
        token: "lin_api_token_register_question",
        webhook_secret: "whsec_register_question"
      })

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Register Question Project 7901",
        github_repo: "org/register-question-7901",
        github_installation_id: 7901,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_register_question_7901",
        linear_team_key: "P7901",
        default_branch: "main",
        clone_path: "/tmp/repos/register-question-7901",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    roles =
      Map.new([:product, :design, :architect, :engineer, :review, :qa, :qa_lead, :demo], fn stage ->
        {:ok, role} =
          Roles.create_role(scope, project, %{
            backend_id: backend.id,
            stage: stage,
            name: "#{stage} role",
            model: "claude-3-7-sonnet",
            system_prompt: "You are the #{stage} agent."
          })

        {stage, role}
      end)

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_register_question_1",
      "identifier" => "RGQ-1",
      "title" => "Register Question Issue"
    })

    {:ok, issue} = Issues.create_issue(project, %{description: "Register Question Issue"})

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
      Runs.create_run(%{
        task_id: task_id,
        role_id: role.id,
        status: :running,
        started_at: DateTime.utc_now()
      })

    run = Repo.preload(run, task: :issue)

    detector = %DetectedQuestion{
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
      Runs.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :running,
        started_at: DateTime.utc_now()
      })

    run = Repo.preload(run, task: :issue)

    detected = Runs.detect_question("[QUESTION: Which cache backend?] [OPTIONS: Redis, ETS]")

    assert {:ok, %Question{prompt: "Which cache backend?", options: ["Redis", "ETS"]}} =
             Pipeline.register_question(run, detected)
  end

  test "belongs to the run that asked", %{task: task, roles: roles} do
    {:ok, task} =
      Pipeline.update_task(task, %{
        stage: :engineer
      })

    {:ok, run} =
      Runs.create_run(%{
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
      Runs.create_run(%{
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
      Runs.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :running,
        started_at: DateTime.utc_now()
      })

    run = Repo.preload(run, task: :issue)

    {:ok, %Question{id: existing_id}} =
      Pipeline.register_question(run, %DetectedQuestion{
        prompt: "Should we use PostgreSQL?",
        role_id: role.id
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
      Runs.create_run(%{
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
      Runs.create_run(%{
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
      Runs.create_run(%{
        task_id: task.id,
        role_id: roles[:engineer].id,
        status: :running,
        started_at: DateTime.utc_now()
      })

    run = Repo.preload(run, task: :issue)

    assert {:error, :invalid_prompt} = Pipeline.register_question(run, %DetectedQuestion{prompt: "   "})
  end
end
