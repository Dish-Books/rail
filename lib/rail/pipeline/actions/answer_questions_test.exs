defmodule Rail.Pipeline.Actions.AnswerQuestionsTest do
  use Rail.DataCase, async: true

  import Rail.Pipeline.Utils.QuestionQueue

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Runs
  alias Rail.Runs.Schemas.OsProcess
  alias Rail.Runs.Schemas.Run
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    scope = system_scope()

    {:ok, backend} =
      Rail.Backends.create_backend(scope, %{name: :claude, executable_path: "/bin/sleep"})

    {:ok, workspace} =
      Projects.upsert_linear_workspace(scope, %{
        name: "Answer Questions Workspace",
        external_id: "lin_ws_answer_questions",
        token: "lin_api_token_answer_questions",
        webhook_secret: "whsec_answer_questions"
      })

    tmp_dir = Path.join(System.tmp_dir!(), "answer_questions_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(tmp_dir, "worktree"))
    on_exit(fn -> File.rm_rf(tmp_dir) end)

    {:ok, project} =
      Projects.create_project(scope, %{
        name: "Answer Questions Project 9101",
        github_repo: "org/answer-questions-9101",
        github_installation_id: 9101,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_answer_questions_9101",
        linear_team_key: "P9101",
        default_branch: "main",
        clone_path: Path.join(tmp_dir, "clone")
      })

    {:ok, role} =
      Roles.create_role(scope, project, %{
        backend_id: backend.id,
        stage: :product,
        name: "product role",
        model: "claude-3-7-sonnet",
        system_prompt: "You are the product agent."
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_answer_questions_1",
      "identifier" => "ANQ-9101",
      "title" => "Answer Questions Issue"
    })

    {:ok, issue} = Issues.capture_issue(scope, project, "Answer Questions Issue")
    {:ok, task} = Pipeline.create_task(issue, :product)

    {:ok, task} =
      Pipeline.update_task(scope, task.id, %{
        stage_state: :blocked,
        worktree_path: Path.join(tmp_dir, "worktree"),
        scratch_path: Path.join(tmp_dir, "scratch")
      })

    {:ok, run} =
      Runs.create_run(%{
        task_id: task.id,
        role_id: role.id,
        conversation_id: "sess_answer_questions",
        status: :blocked_on_input,
        started_at: DateTime.utc_now()
      })

    %{task: task, role: role, run: run, run_id: run.id}
  end

  test "an unanswered question keeps the task parked on the next one", %{task: task, run: run} do
    first =
      Repo.insert!(%Question{task_id: task.id, run_id: run.id, prompt: "Which database?", status: :pending})

    %Question{id: second_id} =
      Repo.insert!(%Question{task_id: task.id, run_id: run.id, prompt: "Ship behind a flag?", status: :pending})

    assert {:ok, %{task: %Task{stage_state: :blocked}}} =
             Pipeline.answer_questions(task, %{first.id => "Postgres"})

    assert Enum.map(pending_questions(task.id), & &1.id) == [second_id]
    assert Repo.get!(Question, first.id).status == :answered
    refute Repo.get!(Question, first.id).delivered_at
  end

  test "answering the batch hands the whole round back on the run that asked", %{
    task: task,
    run: run,
    run_id: run_id
  } do
    first =
      Repo.insert!(%Question{task_id: task.id, run_id: run.id, prompt: "Which database?", status: :pending})

    second =
      Repo.insert!(%Question{task_id: task.id, run_id: run.id, prompt: "Ship behind a flag?", status: :pending})

    test_pid = self()

    expect(Runs, :start_os_process, fn %Run{id: ^run_id} = spawned, argv, opts ->
      send(test_pid, {:spawned, argv, opts})
      {:ok, %OsProcess{is_chat: false, run: spawned, task: task}}
    end)

    assert {:ok, %OsProcess{is_chat: false, run: %Run{id: ^run_id}}} =
             Pipeline.answer_questions(task, %{first.id => "Postgres", second.id => "Yes, behind a flag"})

    # The turn resumes the same conversation rather than starting a new run.
    assert Repo.get!(Run, run.id).conversation_id == "sess_answer_questions"

    assert_receive {:spawned, argv, opts}
    refute opts[:is_chat]
    assert Enum.any?(argv, &(&1 =~ "Postgres" and &1 =~ "Yes, behind a flag"))

    assert pending_questions(task.id) == []
    assert Repo.get!(Question, first.id).delivered_at
    assert Repo.get!(Question, second.id).delivered_at
  end

  test "rejects a blank answer and an answer for another task's question", %{task: task, run: run} do
    question =
      Repo.insert!(%Question{task_id: task.id, run_id: run.id, prompt: "Which database?", status: :pending})

    assert {:error, :no_answers} = Pipeline.answer_questions(task, %{question.id => "   "})
    assert {:error, :no_answers} = Pipeline.answer_questions(task, %{"qst_nonexistent" => "Postgres"})
    assert Repo.get!(Question, question.id).status == :pending
  end

  test "requires an authorized scope", %{task: task, run: run} do
    question =
      Repo.insert!(%Question{task_id: task.id, run_id: run.id, prompt: "Which database?", status: :pending})

    assert {:error, :not_authorized} =
             Pipeline.answer_questions(%Rail.Scope{}, task, %{question.id => "Postgres"})
  end

  test "reports not_found for an unknown task" do
    assert {:error, :not_found} =
             Pipeline.answer_questions("tsk_000000000000000000000000", %{"qst_x" => "y"})
  end
end
