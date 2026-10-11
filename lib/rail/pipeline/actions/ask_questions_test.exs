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
