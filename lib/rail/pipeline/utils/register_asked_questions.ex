defmodule Rail.Pipeline.Utils.RegisterAskedQuestions do
  @moduledoc """
  The questions one finished OS process asked, filed against its task.

  What the agent asked through `ask_questions` becomes the round once its turn is over. Marker lines from an older
  brief are read from this process's own lines of the log, so a question answered two turns ago is not asked again.

  Each new question goes through the questions gate first: one a person already
  answered is answered by Rail with that answer, and a likely match is offered.
  """

  import Ecto.Query
  import Rail.Pipeline.Utils.DetectQuestions

  alias Rail.Learnings
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.RunEvent
  alias Rail.Repo
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess

  # Everything Rail, the tools, the human or a subagent contributed carries one of
  # these markers; what the agent said carries none. A subagent's questions are its lead's to relay.
  @markers [
    "[subagent",
    "[within",
    "[tool]",
    "[tool error",
    "[init]",
    "[result]",
    "[denied]",
    "[recovered]",
    "[rate limit]",
    "[rail]",
    "[human",
    "[reminder",
    "[answered from past answers]",
    "[handoff]",
    "[stderr]",
    "[error]"
  ]

  @doc """
  Registers every question `os_process` asked, the tool's then the marker lines', parking the run on them.
  Returns `[]` when it asked nothing, which tells the caller the stage is free to move on.
  """
  def register_asked_questions(%OsProcess{} = os_process, %Run{} = run) do
    run = Repo.preload(run, [:role, task: :issue], force: true)
    asked = round_up(run)
    detected = os_process |> agent_log(run) |> detect_questions()

    filed =
      for detected <- detected,
          {:ok, %Question{} = question} <- [Pipeline.register_question(run, detected)],
          do: question

    for %Question{status: :pending, suggested_learning_id: nil} = question <- Enum.uniq_by(asked ++ filed, & &1.id) do
      gate(run, question)
    end

    asked ++ detected
  end

  # What the run asked through the tool this turn becomes its round, oldest first, ahead of any marker line.
  defp round_up(%Run{id: run_id} = run) do
    {_count, asked} =
      Repo.update_all(
        from(q in Question, where: q.run_id == ^run_id and q.status == :asked, select: q),
        set: [status: :pending, updated_at: DateTime.utc_now()]
      )

    if asked != [], do: run |> Run.changeset(%{status: :blocked_on_input}) |> Repo.update!()

    Enum.sort_by(asked, &{DateTime.to_unix(&1.inserted_at, :microsecond), &1.id})
  end

  defp gate(%Run{task: task}, %Question{} = question) do
    case Learnings.match_past_answer(task, question) do
      {:answer, %{learning: learning, answer: answer}} ->
        question
        |> Question.changeset(%{
          answer: answer,
          status: :answered,
          answered_at: DateTime.utc_now(),
          answered_by_rail: true,
          suggested_learning_id: learning.id
        })
        |> Repo.update!()

      {:suggestion, %{learning: learning}} ->
        question |> Question.changeset(%{suggested_learning_id: learning.id}) |> Repo.update!()

      nil ->
        question
    end
  end

  # The agent's own words for one OS process, oldest first.
  defp agent_log(%OsProcess{}, %Run{role: nil}), do: ""

  defp agent_log(%OsProcess{id: os_process_id}, %Run{role: %{cli: cli}}) do
    lines = os_process_id |> events_from() |> Enum.map(& &1.line)

    cli
    |> Tools.parse_stream(lines)
    |> Map.fetch!(:logs)
    |> Enum.reject(&tagged?/1)
    |> Enum.join("\n")
  end

  defp events_from(os_process_id) do
    Repo.all(
      from e in RunEvent,
        where: e.os_process_id == ^os_process_id,
        order_by: [asc: e.seq]
    )
  end

  defp tagged?(line), do: Enum.any?(@markers, &String.starts_with?(line, &1))
end
