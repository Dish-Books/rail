defmodule Rail.Pipeline.Actions.DismissQuestion do
  @moduledoc """
  Dismisses a pending agent question: the human saw it and is not answering it.

  Dismissing one of a batch leaves the rest, and the next in the queue goes in front.
  Dismissing the last of them ends the round like answering it would, so the agent is
  resumed with the answers it did get and told which questions were waved off.
  """

  import Rail.Pipeline.Utils.DeliverResolvedRound
  import Rail.Pipeline.Utils.QuestionQueue

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc """
  Dismisses a question with scope authorization.
  """
  def dismiss_question(%Question{} = question) do
    with :ok <- validate_pending(question) do
      do_dismiss_question(question)
    end
  end

  defp validate_pending(%Question{status: :pending}), do: :ok
  defp validate_pending(%Question{}), do: {:error, :already_resolved}

  defp do_dismiss_question(%Question{} = question) do
    {:ok, updated_question} =
      question
      |> Question.changeset(%{status: :dismissed})
      |> Repo.update()

    case Repo.get(Task, updated_question.task_id) do
      # TODO: we don't need to do this, the frontend has the list of questions and a user is actively working on them and goes to the next
      %Task{} = task -> resolve_front_of_queue(task)
      nil -> :ok
    end

    {:ok, updated_question}
  end

  defp resolve_front_of_queue(%Task{} = task) do
    case next_pending_question(task.id) do
      %Question{} = next_question ->
        Pipeline.broadcast_pipeline_changed(%{
          task_id: task.id,
          event: :question_registered,
          question_id: next_question.id
        })

      nil ->
        deliver_resolved_round(task)
    end
  end
end
