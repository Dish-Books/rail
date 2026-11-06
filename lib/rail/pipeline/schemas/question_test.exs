defmodule Rail.Pipeline.Schemas.QuestionTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Roles

  setup %{project: project} do
    stub(Git, :read_default_branch_file, fn _project, path -> {:error, "fatal: path '#{path}' does not exist"} end)

    {:ok, backend} =
      Rail.Tools.create_backend(system_scope(), %{name: :claude, executable_path: "/usr/bin/true"})

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{
              "id" => "lin_question_schema_1",
              "identifier" => "QSC-1",
              "title" => "Question Schema Issue"
            }
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Question Schema Issue"})

    {:ok, task} = Pipeline.create_task(issue, :plan)

    {:ok, role} = Roles.get_role(project_id: project.id, stage: :plan)

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :running,
        started_at: DateTime.utc_now()
      })

    %{backend: backend, project: project, issue: issue, task: task, run: run}
  end

  test "changeset validates required fields" do
    assert %{
             task_id: ["can't be blank"],
             run_id: ["can't be blank"],
             prompt: ["can't be blank"]
           } = errors_on(Question.changeset(%Question{}, %{}))

    assert %{
             status: ["can't be blank"]
           } = errors_on(Question.changeset(%Question{}, %{status: nil}))
  end

  test "changeset accepts valid attributes and sets defaults", %{task: task, run: run} do
    attrs = %{
      run_id: run.id,
      prompt: "Which approach should we take?",
      options: ["Approach 1", "Approach 2"],
      answer: "Approach 1",
      status: :answered,
      answered_at: DateTime.utc_now()
    }

    changeset = Question.changeset(%Question{}, attrs, task.id)

    assert changeset.valid?
    assert get_field(changeset, :task_id) == task.id
    assert get_field(changeset, :status) == :answered
    assert get_field(changeset, :options) == ["Approach 1", "Approach 2"]
  end

  test "changeset validates status enum", %{task: task} do
    assert %{status: ["is invalid"]} =
             errors_on(
               Question.changeset(
                 %Question{},
                 %{prompt: "Prompt?", status: "invalid_status"},
                 task.id
               )
             )
  end

  test "statuses/0, pending?/1, and resolved?/1 helpers" do
    assert Question.statuses() == [:asked, :pending, :unanswered, :answered, :dismissed]

    assert Question.pending?(:pending)
    refute Question.pending?(:answered)
    refute Question.pending?(:dismissed)
    refute Question.pending?(:invalid)
    refute Question.pending?(nil)
    refute Question.pending?("pending")
    refute Question.pending?(123)

    assert Question.resolved?(:answered)
    assert Question.resolved?(:dismissed)
    refute Question.resolved?(:pending)
    refute Question.resolved?(:invalid)
    refute Question.resolved?(nil)
    refute Question.resolved?("answered")
    refute Question.resolved?(123)
  end

  test "validates foreign key on task_id", %{run: run} do
    assert {:error, %{errors: [task_id: {"does not exist", _details}]}} =
             %Question{}
             |> Question.changeset(
               %{prompt: "Missing task prompt", run_id: run.id},
               "tsk_000000000000000000000000"
             )
             |> Repo.insert()
  end

  test "preloads belongs_to task and run", %{task: task, run: %Run{id: run_id} = run} do
    %Task{id: task_id} = task = task

    question =
      Repo.insert!(
        Question.changeset(
          %Question{},
          %{
            prompt: "Question for role?",
            run_id: run.id
          },
          task.id
        )
      )

    preloaded = Repo.preload(question, [:task, :run])

    assert %Question{
             task: %Task{id: ^task_id},
             run: %Run{id: ^run_id}
           } = preloaded
  end

  describe "the answers message" do
    setup do
      at = ~U[2026-10-02 10:00:00.000000Z]
      sent = ~U[2026-10-03 10:00:00.000000Z]

      round = [
        %Question{id: "qst_a1", prompt: "Which database?", status: :answered, answer: "Postgres", inserted_at: at},
        %Question{
          id: "qst_a2",
          prompt: "Behind a flag?",
          status: :answered,
          answer: "Yes.",
          answered_by_rail: true,
          suggested_learning_id: "lrn_1",
          inserted_at: DateTime.shift(at, second: 1)
        },
        # Asked in the same instant as the next, so its id keeps it first.
        %Question{
          id: "qst_a3",
          prompt: "Who reviews it?",
          status: :dismissed,
          inserted_at: DateTime.shift(at, second: 3)
        },
        %Question{
          id: "qst_a4",
          prompt: "Which cache?",
          status: :answered,
          answer: "None.",
          answered_by_rail: true,
          inserted_at: DateTime.shift(at, second: 3)
        }
      ]

      %{
        round: Enum.map(round, &%{&1 | delivered_at: sent}),
        citations: %{"lrn_1" => "Dana Okafor's answer on RAIL-31, Oct 2"}
      }
    end

    test "says each answer in order, a dismissal plainly and whose past answer Rail's came from", %{
      round: round,
      citations: citations
    } do
      assert Question.calculate_answers_message(round, citations) == """
             You asked 4 questions. Answers, in order:

             1. You asked: Which database?
                The answer is: Postgres

             2. You asked: Behind a flag?
                Answered by Rail from Dana Okafor's answer on RAIL-31, Oct 2: Yes.

             3. You asked: Who reviews it?
                Dismissed without an answer; carry on without it.

             4. You asked: Which cache?
                Answered by Rail from a past answer: None.\
             """

      assert Question.calculate_answers_message([hd(round)], citations) ==
               "You asked: Which database?\nThe answer is: Postgres"
    end

    test "reads a delivered round back in the order asked, with each Rail answer's citation as it was sent", %{
      round: [first, second, third, fourth] = round,
      citations: citations
    } do
      # The log keeps a sent line without its indent.
      text = round |> Question.calculate_answers_message(citations) |> String.replace("\n   ", "\n")

      assert [
               %{question: ^first, citation: nil},
               %{question: ^second, citation: %{by: "Dana Okafor", identifier: "RAIL-31", date: "Oct 2"}},
               %{question: ^third, citation: nil},
               %{question: ^fourth, citation: nil}
             ] = Question.parse_answers_message(text, Enum.reverse(round))

      only = "You asked: Behind a flag?\nAnswered by Rail from Dana's answer, Oct 2: Yes."
      lone = [%{second | delivered_at: ~U[2026-10-04 10:00:00.000000Z]}]

      assert [%{citation: %{by: "Dana", identifier: nil, date: "Oct 2"}}] = Question.parse_answers_message(only, lone)

      odd = "You asked: Behind a flag?\nAnswered by Rail from somewhere: Yes."
      assert [%{citation: nil}] = Question.parse_answers_message(odd, lone)

      # A citation holding the words after it ends where the rest of the message still matches.
      echoed = "You asked: Behind a flag?\nAnswered by Rail from Dana: Yes. Bo's answer, Oct 2: Yes."
      assert [%{citation: %{by: "Dana: Yes. Bo", date: "Oct 2"}}] = Question.parse_answers_message(echoed, lone)
    end

    test "reads back a round too long to match as one regex", %{round: [first, second | _rest]} do
      long = String.duplicate("Which of the grid's columns keeps its filter once the page reloads? ", 60)

      round =
        for n <- 1..40 do
          question = if rem(n, 2) == 0, do: second, else: first
          %{question | id: "qst_#{n}", prompt: "#{n}. #{long}", inserted_at: DateTime.shift(first.inserted_at, second: n)}
        end

      text = Question.calculate_answers_message(round, %{"lrn_1" => "Dana's answer, Oct 2"})

      assert parsed = Question.parse_answers_message(text, round)
      assert length(parsed) == 40
      assert %{citation: %{by: "Dana", date: "Oct 2"}} = Enum.at(parsed, 1)
    end

    test "a typed message, a round not yet sent, or answers that differ from the rows read as no round", %{
      round: round,
      citations: citations
    } do
      text = Question.calculate_answers_message(round, citations)

      assert Question.parse_answers_message("You asked: why group by file? Because the tray reads that way.", round) ==
               nil

      assert Question.parse_answers_message(text, Enum.map(round, &%{&1 | delivered_at: nil})) == nil
      assert Question.parse_answers_message(String.replace(text, "Postgres", "SQLite"), round) == nil
      assert Question.parse_answers_message("Looks good.", round) == nil
    end
  end
end
