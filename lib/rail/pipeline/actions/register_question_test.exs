defmodule Rail.Pipeline.Actions.RegisterQuestionTest do
  use Rail.DataCase, async: true

  import Ecto.Query

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Runs
  alias Rail.Runs.QuestionDetector
  alias Rail.Runs.Schemas.RoleRun
  alias Rail.Runs.Schemas.RunEvent
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
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

    {:ok, issue} = Issues.capture_issue(scope, project, "Register Question Issue")

    LinearMock.mock_update_issue_success(%{"id" => "lin_register_question_1"})

    {:ok, task} = Pipeline.create_task(issue)

    %{project: project, issue: issue, task: task, roles: roles}
  end

  test "registers a detected question struct and blocks task and role run", %{task: task, roles: roles} do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")

    role = roles[:engineer]

    {:ok, %Task{id: task_id, title: task_title}} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :engineer,
        stage_state: :running
      })

    {:ok, role_run} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: role.id,
        status: :running,
        started_at: DateTime.utc_now()
      })

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

  test "registers question using raw string with marker", %{task: task, roles: roles} do
    role = roles[:engineer]

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :engineer,
        stage_state: :running
      })

    {:ok, role_run} =
      Runs.create_role_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :running,
        started_at: DateTime.utc_now()
      })

    raw_text = "[QUESTION: Which cache backend?] [OPTIONS: Redis, ETS]"

    assert {:ok, %Question{prompt: "Which cache backend?", options: ["Redis", "ETS"]}} =
             Pipeline.register_question(task, role_run, raw_text)
  end

  test "registers question using map attributes and resolves role when role_run is nil", %{task: task, roles: roles} do
    _role = roles[:engineer]

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :engineer,
        stage_state: :running
      })

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

  test "duplicate suppression: drops question if role_run has pending_answer", %{task: task, roles: roles} do
    Phoenix.PubSub.subscribe(Rail.PubSub, "run:test_role_run")

    role = roles[:engineer]

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :engineer,
        stage_state: :running
      })

    {:ok, role_run} =
      Runs.create_role_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :running,
        started_at: DateTime.utc_now(),
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

  test "duplicate suppression: reuses existing pending question with case-insensitively identical prompt", %{
    task: task,
    roles: roles
  } do
    role = roles[:engineer]

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :engineer,
        stage_state: :running
      })

    {:ok, role_run} =
      Runs.create_role_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :running,
        started_at: DateTime.utc_now()
      })

    {:ok, %Question{id: existing_id}} =
      Pipeline.register_question(task, %{
        prompt: "Should we use PostgreSQL?",
        role_id: role.id
      })

    # Incoming question has different casing and extra spaces
    detector = %QuestionDetector{prompt: "  should we use postgresql?  ", options: []}

    assert {:ok, %Question{id: ^existing_id}} = Pipeline.register_question(task, role_run, detector)

    assert %Task{stage_state: :blocked, question_id: ^existing_id} = Repo.get!(Task, task.id)
  end

  test "single-question-per-run limit: ignores question if task is already blocked on a question", %{
    task: task,
    roles: roles
  } do
    role = roles[:engineer]

    {:ok, q} =
      Pipeline.register_question(task, %{
        prompt: "Question prompt 7909?"
      })

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage_state: :blocked,
        question_id: q.id
      })

    {:ok, role_run} =
      Runs.create_role_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :blocked_on_input,
        started_at: DateTime.utc_now()
      })

    detector = %QuestionDetector{prompt: "Second question in same run?", options: []}

    assert {:ok, :already_registered} = Pipeline.register_question(task, role_run, detector)
    assert Repo.get!(Task, task.id).question_id == q.id
  end

  test "error cases: not found, invalid prompt, no question detected", %{project: project, task: task} do
    assert {:error, :task_not_found} = Pipeline.register_question("tsk_missing", %{prompt: "Q?"})
    assert {:error, :task_not_found} = Pipeline.register_question(123, %{prompt: "Q?"})

    # Task without a role resolves role_id to nil
    {:ok, task_no_role} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :design
      })

    assert {:ok, %Question{prompt: "Q?"}} = Pipeline.register_question(task_no_role, %{prompt: "Q?"}, [])

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_register_question_7902",
      "identifier" => "TSK-7902",
      "title" => "Task 7902"
    })

    {:ok, issue_7902} = Issues.capture_issue(system_scope(), project, "Task 7902")

    LinearMock.mock_update_issue_success(%{"id" => "lin_task_register_question_7902"})

    {:ok, task} = Pipeline.create_task(issue_7902)
    assert {:error, :invalid_prompt} = Pipeline.register_question(task, %{prompt: "   "})
    assert {:error, :no_question_detected} = Pipeline.register_question(task, "Just some prose text")
    assert {:error, :invalid_question_attrs} = Pipeline.register_question(task, 12_345)
  end
end
