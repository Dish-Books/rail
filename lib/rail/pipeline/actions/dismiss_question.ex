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
  alias Rail.Scope

  @doc """
  Dismisses a question with scope authorization.
  """
  def dismiss_question(%Scope{} = scope, question_or_id) do
    with :ok <- authorize_scope(scope),
         %Question{} = question <- resolve_question(question_or_id),
         :ok <- validate_pending(question) do
      do_dismiss_question(question)
    else
      {:error, reason} -> {:error, reason}
      nil -> {:error, :not_found}
    end
  end

  def dismiss_question(question_or_id) do
    dismiss_question(Scope.for_system(), question_or_id)
  end

  defp authorize_scope(%Scope{system: true}), do: :ok
  defp authorize_scope(%Scope{user: %{}}), do: :ok
  defp authorize_scope(_scope), do: {:error, :not_authorized}

  defp validate_pending(%Question{status: :pending}), do: :ok
  defp validate_pending(%Question{}), do: {:error, :already_resolved}

  defp do_dismiss_question(%Question{} = question) do
    {:ok, updated_question} =
      question
      |> Question.changeset(%{status: :dismissed})
      |> Repo.update()

    case Repo.get(Task, updated_question.task_id) do
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

  defp resolve_question(%Question{} = question), do: question
  defp resolve_question(id) when is_binary(id), do: Repo.get(Question, id)
  defp resolve_question(_other), do: nil
end
