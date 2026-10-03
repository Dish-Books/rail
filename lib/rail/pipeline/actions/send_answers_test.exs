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
               learning: %Learning{status: :provisional, kind: :decision, rule: "Postgres"}
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
end
