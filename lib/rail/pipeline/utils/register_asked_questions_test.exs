defmodule Rail.Pipeline.Utils.RegisterAskedQuestionsTest do
  use Rail.DataCase, async: true

  import Rail.Pipeline.Utils.QuestionQueue
  import Rail.Pipeline.Utils.RegisterAskedQuestions

  alias Rail.Issues
  alias Rail.Learnings.Schemas.Learning
  alias Rail.Pipeline
  alias Rail.Pipeline.DetectedQuestion
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.RunEvent
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Roles
  alias Rail.Tools.Schemas.OsProcess

  setup %{project: project} do
    {:ok, role} = Roles.get_role(project_id: project.id, stage: :plan)

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{
              "id" => "lin_run_finished_1",
              "identifier" => "RFN-1",
              "title" => "Run Finished Issue"
            }
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Run Finished Issue"})
    {:ok, task} = Pipeline.create_task(issue, :plan)

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        conversation_id: "sess_run_finished",
        status: :running,
        started_at: DateTime.utc_now()
      })

    spawn_os_process = fn ->
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: run.task_id,
        stream_path: "/tmp/run_finished/#{UXID.generate!()}.ndjson",
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()
    end

    say = fn os_process, text ->
      Repo.insert!(%RunEvent{
        run_id: run.id,
        os_process_id: os_process.id,
        line: ~s({"type":"assistant","message":{"content":[{"type":"text","text":"#{text}"}]}})
      })
    end

    %{task: task, run: run, spawn_os_process: spawn_os_process, say: say}
  end

  test "files only the questions the exiting process itself asked", %{
    task: %Task{id: task_id},
    run: run,
    spawn_os_process: spawn_os_process,
    say: say
  } do
    first = spawn_os_process.()
    say.(first, "[QUESTION: Which database?] [OPTIONS: Postgres, SQLite]")

    second = spawn_os_process.()
    say.(second, "[QUESTION: Which region?]")

    assert [%DetectedQuestion{prompt: "Which database?"}] = register_asked_questions(first, run)

    assert [%Question{prompt: "Which database?", options: ["Postgres", "SQLite"]}] =
             pending_questions(task_id)
  end

  test "registers a batch in the order it was asked, parks the task, and blocks the run", %{
    task: %Task{id: task_id},
    run: run,
    spawn_os_process: spawn_os_process,
    say: say
  } do
    os_process = spawn_os_process.()
    say.(os_process, "[QUESTION: Which database?] [OPTIONS: PG, MySQL]")
    say.(os_process, "[QUESTION: Ship behind a flag?]")
    say.(os_process, "[QUESTION: Which database?]")

    assert [%DetectedQuestion{}, %DetectedQuestion{}] = register_asked_questions(os_process, run)

    pending = pending_questions(task_id)
    assert Enum.map(pending, & &1.prompt) == ["Which database?", "Ship behind a flag?"]

    assert %Task{} = Repo.get!(Task, task_id)
    assert %Run{status: :blocked_on_input} = Repo.get!(Run, run.id)
  end

  test "settles a process that asked nothing without parking the task", %{
    task: %Task{id: task_id},
    run: run,
    spawn_os_process: spawn_os_process,
    say: say
  } do
    os_process = spawn_os_process.()
    say.(os_process, "Postgres it is.")

    assert register_asked_questions(os_process, run) == []
    assert pending_questions(task_id) == []
  end

  test "leaves out what Rail and the human contributed between turns", %{
    task: %Task{id: task_id},
    run: run,
    spawn_os_process: spawn_os_process,
    say: say
  } do
    os_process = spawn_os_process.()
    say.(os_process, "[QUESTION: Which database?]")

    Repo.insert!(%RunEvent{
      run_id: run.id,
      os_process_id: os_process.id,
      line: "[human] [QUESTION: Have you taken another look?]"
    })

    Repo.insert!(%RunEvent{
      run_id: run.id,
      os_process_id: os_process.id,
      line: "[human:usr_dana] Looks close.\n[QUESTION: Is this done yet?]"
    })

    Repo.insert!(%RunEvent{
      run_id: run.id,
      os_process_id: os_process.id,
      line: "[reminder 1 of 2] Attach a screenshot.\n[QUESTION: Where is the evidence?]"
    })

    assert [%DetectedQuestion{prompt: "Which database?"}] =
             register_asked_questions(os_process, run)

    assert [%Question{prompt: "Which database?"}] = pending_questions(task_id)
  end

  test "a subagent's question is its lead's to relay, so it is not filed", %{
    task: %Task{id: task_id},
    run: run,
    spawn_os_process: spawn_os_process,
    say: say
  } do
    os_process = spawn_os_process.()

    Repo.insert!(%RunEvent{
      run_id: run.id,
      os_process_id: os_process.id,
      line:
        ~s({"type":"assistant","parent_tool_use_id":"toolu_pm","message":{"content":[{"type":"text","text":"[QUESTION: Which team?]"}]}})
    })

    say.(os_process, "[QUESTION: Which database?]")

    assert [%DetectedQuestion{prompt: "Which database?"}] = register_asked_questions(os_process, run)
    assert [%Question{prompt: "Which database?"}] = pending_questions(task_id)
  end

  test "a run whose role is gone has no agent to have asked anything", %{
    task: %Task{id: task_id},
    run: run,
    spawn_os_process: spawn_os_process,
    say: say
  } do
    os_process = spawn_os_process.()
    say.(os_process, "[QUESTION: Which database?]")

    {:ok, _deleted} = Roles.delete_role(system_scope(), Repo.preload(run, :role).role)

    assert register_asked_questions(os_process, run) == []
    assert pending_questions(task_id) == []
  end

  describe "the questions gate" do
    setup %{project: project} do
      earlier = learnings_task(project, "GTE-1")
      past = %Question{id: "qst_gate_past", prompt: "Postgres or SQLite?", answer: "Postgres.", status: :answered}
      {:ok, [rule]} = Rail.Learnings.record_corrections(earlier, [past])

      Repo.update_all(from(l in Learning, where: l.id == ^rule.id),
        set: [embedding: Pgvector.new(vector([1.0])), embedding_model: "gemini-embedding-001"]
      )

      stub_vertex(%{"Which database" => vector([1.0, 0.1]), "Which store" => vector([1.0, 0.6])})
      %{rule: rule}
    end

    test "a strong match is answered by Rail with its source, a likely one carries the suggestion, the rest stay plain",
         %{
           task: %Task{id: task_id},
           run: run,
           rule: %{id: rule_id},
           spawn_os_process: spawn_os_process,
           say: say
         } do
      os_process = spawn_os_process.()
      say.(os_process, "[QUESTION: Which database?]")
      say.(os_process, "[QUESTION: Which store for blobs?]")
      say.(os_process, "[QUESTION: Ship behind a flag?]")

      assert [_one, _two, _three] = register_asked_questions(os_process, run)

      assert [
               %Question{
                 prompt: "Which database?",
                 status: :answered,
                 answer: "Postgres.",
                 answered_by_rail: true,
                 suggested_learning_id: ^rule_id
               },
               %Question{
                 prompt: "Which store for blobs?",
                 status: :pending,
                 answer: nil,
                 suggested_learning_id: ^rule_id
               },
               %Question{prompt: "Ship behind a flag?", status: :pending, suggested_learning_id: nil}
             ] = Repo.all(from q in Question, where: q.task_id == ^task_id, order_by: [asc: q.inserted_at, asc: q.id])
    end

    test "a rule a person reworded answers with what it says now", %{
      task: %Task{id: task_id},
      run: run,
      rule: rule,
      spawn_os_process: spawn_os_process,
      say: say
    } do
      {:ok, _edited} = Rail.Learnings.update_learning(system_scope(), rule, %{rule: "Postgres, with pgvector."})

      Repo.update_all(from(l in Learning, where: l.id == ^rule.id),
        set: [embedding: Pgvector.new(vector([1.0])), embedding_model: "gemini-embedding-001"]
      )

      os_process = spawn_os_process.()
      say.(os_process, "[QUESTION: Which database?]")

      assert [_one] = register_asked_questions(os_process, run)

      assert [%Question{status: :answered, answer: "Postgres, with pgvector.", answered_by_rail: true}] =
               Repo.all(from q in Question, where: q.task_id == ^task_id)
    end

    # Taking a suggestion adds a source asked in other words, which leaves the rule as it was made.
    test "a rule a later question joined still answers with the person's words", %{
      project: project,
      task: %Task{id: task_id},
      run: run,
      rule: rule,
      spawn_os_process: spawn_os_process,
      say: say
    } do
      taken = %Question{
        id: "qst_gate_taken",
        prompt: "Which store?",
        answer: "Postgres.",
        status: :answered,
        suggested_learning_id: rule.id
      }

      {:ok, []} = Rail.Learnings.record_corrections(learnings_task(project, "GTE-2"), [taken])
      os_process = spawn_os_process.()
      say.(os_process, "[QUESTION: Which database?]")

      assert [_one] = register_asked_questions(os_process, run)

      assert [%Question{status: :answered, answer: "Postgres.", answered_by_rail: true}] =
               Repo.all(from q in Question, where: q.task_id == ^task_id)
    end
  end
end
