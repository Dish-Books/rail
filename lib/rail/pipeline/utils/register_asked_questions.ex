defmodule Rail.Pipeline.Utils.RegisterAskedQuestions do
  @moduledoc """
  Makes what a run asked through `ask_questions` this turn its round, once the turn is over, and parks the run on it.

  Each new question goes through the questions gate first: one a person already
  answered is answered by Rail with that answer, and a likely match is offered.
  """

  import Ecto.Query

  alias Rail.Learnings
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Repo

  @doc """
  Moves the questions `run` asked this turn into its round, oldest first, parking the run on them.
  Returns `[]` when it asked nothing, which tells the caller the stage is free to move on.
  """
  def register_asked_questions(%Run{id: run_id} = run) do
    {_count, asked} =
      Repo.update_all(
        from(q in Question, where: q.run_id == ^run_id and q.status == :asked, select: q),
        set: [status: :pending, updated_at: DateTime.utc_now()]
      )

    asked = Enum.sort_by(asked, &{DateTime.to_unix(&1.inserted_at, :microsecond), &1.id})

    if asked != [] do
      run = Repo.preload(run, [task: :issue], force: true)
      run |> Run.changeset(%{status: :blocked_on_input}) |> Repo.update!()
      for question <- asked, do: gate(run, question)
    end

    asked
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
end
