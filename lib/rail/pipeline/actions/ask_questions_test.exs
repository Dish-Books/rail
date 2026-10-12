defmodule Rail.Pipeline.Actions.AskQuestionsTest do
  use Rail.DataCase, async: true

  import Rail.Pipeline.Utils.QuestionQueue
  import Rail.Pipeline.Utils.UnsentRound

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Roles

  setup %{project: project} do
    task = learnings_task(project, "ASK-1")
    {:ok, role} = Roles.get_role(project_id: project.id, stage: :engineer)

    {:ok, run} =
      Pipeline.create_run(%{task_id: task.id, role_id: role.id, status: :running, started_at: DateTime.utc_now()})

    %{task: task, run: run}
  end

  test "asked questions leave the run working and stay out of the round and the queue until the turn ends", %{
    task: task,
    run: run
  } do
    assert {:ok, %{asked: [%Question{status: :asked}, %Question{status: :asked}], already: []}} =
             Pipeline.ask_questions(run, [%{"prompt" => "Which database?"}, %{"prompt" => "Behind a flag?"}])

    assert %Run{status: :running} = Repo.reload!(run)
    assert unsent_round(run) == []
    assert pending_questions(task.id) == []
  end

  test "entries are filed in the order given, blank options dropped and the rest trimmed", %{task: task, run: run} do
    {:ok, _asked} =
      Pipeline.ask_questions(run, [
        %{"prompt" => " Which database? ", "options" => ["Postgres ", " ", "SQLite"]},
        %{"prompt" => "Behind a flag?", "options" => nil},
        %{"prompt" => "Who reviews it?"}
      ])

    assert [
             %Question{prompt: "Which database?", options: ["Postgres", "SQLite"]},
             %Question{prompt: "Behind a flag?", options: []},
             %Question{prompt: "Who reviews it?", options: []}
           ] = Pipeline.list_questions(task, order_by: [asc: :inserted_at, asc: :id])
  end

  test "a call's new questions are filed in one insert and come back in the order asked", %{
    task: task,
    run: %Run{id: run_id} = run
  } do
    test_pid = self()
    handler = "ask-questions-#{inspect(test_pid)}"

    # The handler sees every test's queries, so only an insert carrying this run's id is counted.
    :ok =
      :telemetry.attach(
        handler,
        [:rail, :repo, :query],
        fn
          _event, _measurements, %{source: "questions", query: "INSERT" <> _rest, params: params}, _config ->
            if run_id in params, do: send(test_pid, :inserted)

          _event, _measurements, _metadata, _config ->
            :ok
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    prompts = for number <- [12, 3, 7, 1, 10, 5, 9, 2, 11, 4, 8, 6], do: "Question #{number}?"

    {:ok, %{asked: asked, already: [%Question{prompt: "Question 7?"}]}} =
      Pipeline.ask_questions(run, for(prompt <- Enum.concat(prompts, ["question 7?"]), do: %{"prompt" => prompt}))

    assert_received :inserted
    refute_received :inserted
    assert Enum.map(asked, & &1.prompt) == prompts
    assert Enum.map(Pipeline.list_questions(task, order_by: [asc: :inserted_at, asc: :id]), & &1.prompt) == prompts
  end

  test "a prompt the run holds open is reused rather than asked again", %{task: task, run: run} do
    {:ok, %{asked: [%Question{id: held_id}]}} = Pipeline.ask_questions(run, [%{"prompt" => "Which database?"}])
    Repo.update_all(from(q in Question, where: q.id == ^held_id), set: [status: :pending])

    assert {:ok, %{asked: [], already: [%Question{id: ^held_id}]}} =
             Pipeline.ask_questions(run, [%{"prompt" => "WHICH DATABASE?"}])

    assert [%Question{id: ^held_id}] = Pipeline.list_questions(task)
  end

  test "one invalid entry rolls back the whole list", %{task: task, run: run} do
    assert {:error, [{2, %Ecto.Changeset{valid?: false}}]} =
             Pipeline.ask_questions(run, [%{"prompt" => "Which database?"}, %{"prompt" => ""}])

    assert Pipeline.list_questions(task) == []
  end
end
