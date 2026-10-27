defmodule Rail.Pipeline.Utils.RegisterAskedQuestionsTest do
  use Rail.DataCase, async: true

  import Rail.Pipeline.Utils.QuestionQueue
  import Rail.Pipeline.Utils.RegisterAskedQuestions

  alias Rail.Issues
  alias Rail.Learnings.Schemas.Learning
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Roles

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

    %{task: task, run: run}
  end

  test "what the run asked through the tool becomes the round in the order asked, and the run parks", %{
    task: %Task{id: task_id},
    run: run
  } do
    {:ok, _asked} =
      Pipeline.ask_questions(run, [
        %{"prompt" => "Which database?", "options" => ["Postgres"]},
        %{"prompt" => "Behind a flag?"}
      ])

    {:ok, _asked} = Pipeline.ask_questions(run, [%{"prompt" => "Who reviews it?"}])

    assert [%Question{}, %Question{}, %Question{}] = register_asked_questions(run)

    assert [
             %Question{prompt: "Which database?", options: ["Postgres"]},
             %Question{prompt: "Behind a flag?"},
             %Question{prompt: "Who reviews it?"}
           ] = pending_questions(task_id)

    assert %Run{status: :blocked_on_input} = Repo.get!(Run, run.id)
  end

  # Plan's subagents share its token, so a question one asks through the tool is the Plan run's.
  test "a question a subagent asked through the tool and the lead asked again is filed once on the run", %{
    task: %Task{id: task_id},
    run: %Run{id: run_id} = run
  } do
    {:ok, _from_subagent} = Pipeline.ask_questions(run, [%{"prompt" => "Which team owns it?"}])
    {:ok, _from_lead} = Pipeline.ask_questions(run, [%{"prompt" => "Which team owns it?"}, %{"prompt" => "Ship it?"}])

    register_asked_questions(run)

    assert [%Question{run_id: ^run_id, prompt: "Which team owns it?"}, %Question{run_id: ^run_id, prompt: "Ship it?"}] =
             pending_questions(task_id)
  end

  test "a turn that asked nothing leaves another run's asked questions where they are", %{
    task: %Task{id: task_id},
    run: run
  } do
    {:ok, other} =
      Pipeline.create_run(%{task_id: task_id, role_id: run.role_id, status: :running, started_at: DateTime.utc_now()})

    {:ok, _asked} = Pipeline.ask_questions(other, [%{"prompt" => "Which database?"}])

    assert register_asked_questions(run) == []
    assert %Run{status: :running} = Repo.get!(Run, run.id)
    assert [%Question{status: :asked}] = Repo.all(from q in Question, where: q.task_id == ^task_id)
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
           rule: %{id: rule_id}
         } do
      {:ok, _asked} =
        Pipeline.ask_questions(run, [
          %{"prompt" => "Which database?"},
          %{"prompt" => "Which store for blobs?"},
          %{"prompt" => "Ship behind a flag?"}
        ])

      assert [_one, _two, _three] = register_asked_questions(run)

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
      rule: rule
    } do
      {:ok, _edited} = Rail.Learnings.update_learning(system_scope(), rule, %{rule: "Postgres, with pgvector."})

      Repo.update_all(from(l in Learning, where: l.id == ^rule.id),
        set: [embedding: Pgvector.new(vector([1.0])), embedding_model: "gemini-embedding-001"]
      )

      {:ok, _asked} = Pipeline.ask_questions(run, [%{"prompt" => "Which database?"}])

      assert [_one] = register_asked_questions(run)

      assert [%Question{status: :answered, answer: "Postgres, with pgvector.", answered_by_rail: true}] =
               Repo.all(from q in Question, where: q.task_id == ^task_id)
    end

    # Taking a suggestion adds a source asked in other words, which leaves the rule as it was made.
    test "a rule a later question joined still answers with the person's words", %{
      project: project,
      task: %Task{id: task_id},
      run: run,
      rule: rule
    } do
      taken = %Question{
        id: "qst_gate_taken",
        prompt: "Which store?",
        answer: "Postgres.",
        status: :answered,
        suggested_learning_id: rule.id
      }

      {:ok, []} = Rail.Learnings.record_corrections(learnings_task(project, "GTE-2"), [taken])
      {:ok, _asked} = Pipeline.ask_questions(run, [%{"prompt" => "Which database?"}])

      assert [_one] = register_asked_questions(run)

      assert [%Question{status: :answered, answer: "Postgres.", answered_by_rail: true}] =
               Repo.all(from q in Question, where: q.task_id == ^task_id)
    end
  end
end
