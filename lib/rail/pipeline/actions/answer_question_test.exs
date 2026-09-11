defmodule Rail.Pipeline.Actions.AnswerQuestionTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Runs
  alias Rail.Runs.Schemas.RoleRun
  alias Rail.Runs.Schemas.Run
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    scope = system_scope()

    {:ok, workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Answer Question Workspace",
        external_id: "lin_ws_answer_question",
        token: "lin_api_token_answer_question",
        webhook_secret: "whsec_answer_question"
      })

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Answer Question Project 7801",
        github_repo: "org/answer-question-7801",
        github_installation_id: 7801,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_answer_question_7801",
        linear_team_key: "P7801",
        clone_path: "/tmp/repos/answer-question-7801",
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
      "id" => "lin_answer_question_1",
      "identifier" => "ANQ-1",
      "title" => "Answer Question Issue"
    })

    {:ok, issue} = Issues.capture_issue(scope, project, "Answer Question Issue")

    {:ok, task} = Pipeline.create_task(issue, :product)

    %{project: project, issue: issue, task: task, roles: roles}
  end

  test "answers a question, clears task.question_id, and queues stage with formatted pending_answer", %{
    task: task,
    roles: roles
  } do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")

    role = roles[:engineer]

    {:ok, %Task{id: task_id}} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :engineer,
        stage_state: :blocked
      })

    {:ok, role_run} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: role.id,
        status: :blocked_on_input,
        started_at: DateTime.utc_now()
      })

    {:ok, q} =
      Pipeline.register_question(task_id, %{
        prompt: "Use Postgres or MySQL?",
        role_id: role.id
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

  test "appends with newline separator if role_run already had pending_answer", %{task: task, roles: roles} do
    role = roles[:engineer]

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :engineer,
        stage_state: :blocked
      })

    {:ok, role_run} =
      Runs.create_role_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :blocked_on_input,
        started_at: DateTime.utc_now()
      })

    {:ok, q} =
      Pipeline.register_question(task, %{
        prompt: "Port number?",
        role_id: role.id
      })

    {:ok, _role_run} = Runs.update_role_run(role_run, %{pending_answer: "Initial instructions"})

    assert {:ok, %Question{status: :answered}} = Pipeline.answer_question(q.id, "4000")

    expected_pending = "Initial instructions\n\nYou asked: Port number?\nThe answer is: 4000"
    assert %RoleRun{pending_answer: ^expected_pending} = Repo.get!(RoleRun, role_run.id)
  end

  test "stops live running process if task is running and not rebasing", %{task: task, roles: roles} do
    role = roles[:engineer]

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :engineer,
        stage_state: :blocked,
        is_rebasing: false
      })

    {:ok, role_run} =
      Runs.create_role_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :blocked_on_input,
        started_at: DateTime.utc_now()
      })

    {:ok, q} =
      Pipeline.register_question(task, %{
        prompt: "Run tests?",
        role_id: role.id
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
        started_at: DateTime.utc_now()
      })

    assert Runs.is_running?(task.id)

    assert {:ok, %Question{status: :answered}} = Pipeline.answer_question(q.id, "Yes, run all tests")

    reloaded_run = Repo.get!(Run, run.id)
    assert reloaded_run.status == :finished
    refute Runs.is_running?(task.id)
  end

  test "does not stop live process if task is currently rebasing", %{task: task, roles: roles} do
    role = roles[:engineer]

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :engineer,
        stage_state: :blocked,
        is_rebasing: true
      })

    {:ok, role_run} =
      Runs.create_role_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :blocked_on_input,
        started_at: DateTime.utc_now()
      })

    {:ok, q} =
      Pipeline.register_question(task, %{
        prompt: "Rebase onto main?",
        role_id: role.id
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
        started_at: DateTime.utc_now()
      })

    assert Runs.is_running?(task.id)

    assert {:ok, %Question{status: :answered}} = Pipeline.answer_question(q.id, "Yes")

    # Run was not terminated because task is rebasing
    reloaded_run = Repo.get!(Run, run.id)
    assert reloaded_run.status == :running
  end

  test "validates empty answer, already resolved, and missing questions", %{task: task, roles: roles} do
    role = roles[:engineer]

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :engineer,
        stage_state: :blocked
      })

    {:ok, _role_run} =
      Runs.create_role_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :blocked_on_input,
        started_at: DateTime.utc_now()
      })

    {:ok, q} =
      Pipeline.register_question(task, %{
        prompt: "Question prompt 7813?"
      })

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
    {:ok, project_no_role} =
      Projects.create_project(system_scope(), %{
        name: "Answer Question Project 7803",
        github_repo: "org/answer-question-7803",
        github_installation_id: 7803,
        linear_team_id: "team_answer_question_7803",
        linear_team_key: "P7803",
        clone_path: "/tmp/repos/answer-question-7803",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_answer_question_7802",
      "identifier" => "TSK-7802",
      "title" => "Task 7802"
    })

    {:ok, issue_7802} = Issues.capture_issue(system_scope(), project_no_role, "Task 7802")

    {:ok, task_no_role} = Pipeline.create_task(issue_7802, :product)

    {:ok, task_no_role} =
      Pipeline.update_task(system_scope(), task_no_role.id, %{
        stage: :engineer,
        stage_state: :blocked
      })

    {:ok, q_no_role} =
      Pipeline.register_question(task_no_role, %{
        prompt: "Question prompt 7814?"
      })

    assert {:error, :role_not_found} = Pipeline.answer_question(q_no_role, "Answer")
  end
end
