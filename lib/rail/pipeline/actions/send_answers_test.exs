defmodule Rail.Pipeline.Actions.SendAnswersTest do
  use Rail.DataCase, async: true

  alias Rail.Learnings.Schemas.Learning
  alias Rail.Learnings.Schemas.Observation
  alias Rail.Pipeline
  alias Rail.Pipeline.DetectedQuestion
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess

  setup %{project: project} do
    {:ok, role} = Roles.get_role(project_id: project.id, stage: :engineer)
    task = learnings_task(project, "SNA-1")

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :blocked_on_input,
        conversation_id: "sess_sna",
        started_at: DateTime.utc_now()
      })

    stub(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)
    %{task: task, run: Repo.preload(run, task: :issue)}
  end

  test "a person's answers are learned once the round goes out, as they stood then, and Rail's are not", %{
    task: task,
    run: run
  } do
    {:ok, %{id: first_id} = first} = Pipeline.register_question(run, %DetectedQuestion{prompt: "Which database?"})
    {:ok, second} = Pipeline.register_question(run, %DetectedQuestion{prompt: "Behind a flag?"})
    {:ok, _first} = Pipeline.answer_question(system_scope(), first, "MySQL")
    {:ok, _changed} = Pipeline.answer_question(system_scope(), Repo.reload!(first), "Postgres")

    {:ok, _by_rail} =
      second |> Question.changeset(%{answer: "Yes.", status: :answered, answered_by_rail: true}) |> Repo.update()

    assert [] = Repo.all(from o in Observation, where: o.task_id == ^task.id)
    assert {:ok, :sent, _run} = Pipeline.send_answers(system_scope(), Repo.reload!(run))

    assert [
             %Observation{
               source_kind: :answer,
               source_id: ^first_id,
               excerpt: "Postgres",
               learning: %Learning{
                 status: :provisional,
                 kind: :decision,
                 rule: ~s(When asked "Which database?": Postgres)
               }
             }
           ] =
             Repo.all(from o in Observation, where: o.task_id == ^task.id, preload: :learning)
  end

  test "a round that cannot go out learns nothing", %{task: task, run: run} do
    {:ok, question} = Pipeline.register_question(run, %DetectedQuestion{prompt: "Which database?"})
    {:ok, _answered} = Pipeline.answer_question(system_scope(), question, "Postgres")
    {:ok, run} = Pipeline.update_run(Repo.reload!(run), %{status: :finished})
    Repo.update_all(from(r in Rail.Pipeline.Schemas.Run, where: r.id == ^run.id), set: [conversation_id: nil])

    assert {:error, :chat_unavailable} = Pipeline.send_answers(system_scope(), Repo.reload!(run))
    assert [] = Repo.all(from o in Observation, where: o.task_id == ^task.id)
  end

  describe "answers Rail took from past answers" do
    setup %{project: project} do
      {:ok, dana} =
        Rail.Users.register_oauth_user(%{github_id: "sna-1", login: "dana", name: "Dana", email: "dana@sna.example"})

      earlier = learnings_task(project, "SNA-0")
      past = %Question{id: "qst_sna_past", prompt: "Which database?", answer: "Postgres.", status: :answered}
      {:ok, [rule]} = Rail.Learnings.record_corrections(earlier, [%{past | answered_by_id: dana.id}])
      %Observation{inserted_at: at} = Repo.get_by!(Observation, source_id: "qst_sna_past")

      %{rule: rule, cited: "Answered by Rail from Dana's answer on SNA-0, #{Calendar.strftime(at, "%b %-d")}"}
    end

    test "a round Rail answered whole is sent as Rail's, citing whose answer it was", %{
      run: run,
      rule: rule,
      cited: cited
    } do
      {:ok, question} = Pipeline.register_question(run, %DetectedQuestion{prompt: "Which database to use?"})

      {:ok, _by_rail} =
        question
        |> Question.changeset(%{
          answer: rule.rule,
          status: :answered,
          answered_by_rail: true,
          suggested_learning_id: rule.id
        })
        |> Repo.update()

      assert {:ok, :sent, _run} = Pipeline.send_answers(system_scope(), Repo.reload!(run))

      lines = run |> Pipeline.list_run_events() |> Enum.map(& &1.line)
      assert "[answered from past answers] #{cited}: #{rule.rule}" in lines
      refute Enum.any?(lines, &String.starts_with?(&1, "[human]"))
    end

    test "in a round a person also answered, Rail's answer is cited inside the person's message", %{
      run: run,
      rule: rule,
      cited: cited
    } do
      {:ok, first} = Pipeline.register_question(run, %DetectedQuestion{prompt: "Which database to use?"})
      {:ok, second} = Pipeline.register_question(run, %DetectedQuestion{prompt: "Behind a flag?"})
      {:ok, third} = Pipeline.register_question(run, %DetectedQuestion{prompt: "Which cache?"})

      {:ok, _by_rail} =
        first
        |> Question.changeset(%{
          answer: rule.rule,
          status: :answered,
          answered_by_rail: true,
          suggested_learning_id: rule.id
        })
        |> Repo.update()

      {:ok, _by_rail} =
        third |> Question.changeset(%{answer: "None.", status: :answered, answered_by_rail: true}) |> Repo.update()

      {:ok, _answered} = Pipeline.answer_question(system_scope(), second, "Yes")
      assert {:ok, :sent, _run} = Pipeline.send_answers(system_scope(), Repo.reload!(run))

      lines = run |> Pipeline.list_run_events() |> Enum.map(& &1.line)
      assert "[human]    #{cited}: #{rule.rule}" in lines
      assert "[human]    The answer is: Yes" in lines
      assert "[human]    Answered by Rail from a past answer: None." in lines
    end
  end
end
