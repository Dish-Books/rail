defmodule Rail.Pipeline.Actions.AnswerQuestionTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.DetectedQuestion
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess

  setup %{project: project} do
    {:ok, role} = Roles.get_role(project_id: project.id, stage: :engineer)

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{
              "id" => "lin_answer_question_1",
              "identifier" => "ANS-1",
              "title" => "Answer Question Issue"
            }
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Answer Question Issue"})
    {:ok, task} = Pipeline.create_task(issue, :engineer)

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :running,
        conversation_id: "sess_answer_question",
        started_at: DateTime.utc_now()
      })

    run = Repo.preload(run, task: :issue)

    %{project: project, task: task, role: role, run: run}
  end

  test "records the answer and tells the agent nothing", %{run: run} do
    {:ok, question} = Pipeline.register_question(run, %DetectedQuestion{prompt: "Which database?"})

    assert {:ok, %Question{status: :answered, answer: "Postgres", answered_at: %DateTime{}}} =
             Pipeline.answer_question(question, "Postgres")

    assert Pipeline.list_run_events(run) == []
  end

  test "an empty answer is not an answer", %{run: run} do
    {:ok, question} = Pipeline.register_question(run, %DetectedQuestion{prompt: "Which database?"})

    assert {:error, :empty_answer} = Pipeline.answer_question(question, "   ")
  end

  test "a question already settled is not answered again", %{run: run} do
    {:ok, question} = Pipeline.register_question(run, %DetectedQuestion{prompt: "Which database?"})
    {:ok, answered} = Pipeline.answer_question(question, "Postgres")

    assert {:error, :already_resolved} = Pipeline.answer_question(answered, "Sqlite")
  end

  test "the round goes back as one message once nothing is pending", %{run: run} do
    {:ok, first} = Pipeline.register_question(run, %DetectedQuestion{prompt: "Which database?"})
    {:ok, second} = Pipeline.register_question(run, %DetectedQuestion{prompt: "Behind a flag?"})

    {:ok, _answered} = Pipeline.answer_question(first, "Postgres")
    {:ok, _dismissed} = Pipeline.dismiss_question(second)

    stub(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)

    assert {:ok, :sent, %Run{}} = Pipeline.send_answers(Repo.reload!(run))

    assert %Question{delivered_at: %DateTime{}} = Repo.reload!(first)
    assert %Question{delivered_at: %DateTime{}} = Repo.reload!(second)

    lines = run |> Pipeline.list_run_events() |> Enum.map_join("\n", & &1.line)
    assert lines =~ "Which database?"
    assert lines =~ "The answer is: Postgres"
    assert lines =~ "Dismissed without an answer"
  end

  test "nothing goes back while something is still pending", %{run: run} do
    {:ok, first} = Pipeline.register_question(run, %DetectedQuestion{prompt: "Which database?"})
    {:ok, _second} = Pipeline.register_question(run, %DetectedQuestion{prompt: "Behind a flag?"})

    {:ok, _answered} = Pipeline.answer_question(first, "Postgres")

    assert {:error, :questions_pending} = Pipeline.send_answers(Repo.reload!(run))
    refute Repo.reload!(first).delivered_at
  end

  test "a run with no round to hand back sends nothing", %{run: run} do
    assert {:error, :nothing_to_send} = Pipeline.send_answers(Repo.reload!(run))
  end

  test "a single answer reads as one question asked", %{run: run} do
    {:ok, only} = Pipeline.register_question(run, %DetectedQuestion{prompt: "Which database?"})
    {:ok, _answered} = Pipeline.answer_question(only, "Postgres")

    stub(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)

    assert {:ok, :sent, %Run{}} = Pipeline.send_answers(Repo.reload!(run))

    lines = run |> Pipeline.list_run_events() |> Enum.map_join("\n", & &1.line)
    assert lines =~ "You asked: Which database?"
    refute lines =~ "questions. Answers, in order"
  end
end
