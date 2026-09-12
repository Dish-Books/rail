defmodule Rail.Pipeline.Actions.DismissQuestion do
  @moduledoc """
  Action that dismisses a pending agent question.
  Updates the question status to `:dismissed`. If the task was parked on this question,
  the next one in the queue takes its place; the blocked stage is only released, via
  `Rail.Pipeline.release_blocked_stage/2`, once nothing is pending.
  """

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
      do_dismiss_question(scope, question)
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

  defp do_dismiss_question(scope, %Question{} = question) do
    {:ok, updated_question} =
      question
      |> Question.changeset(%{status: :dismissed})
      |> Repo.update()

    case Repo.get(Task, updated_question.task_id) do
      %Task{} = task -> resolve_front_of_queue(scope, task)
      nil -> :ok
    end

    {:ok, updated_question}
  end

  # Dismissing one of a batch leaves the rest: the stage is only released once the
  # whole queue has drained.
  defp resolve_front_of_queue(scope, %Task{} = task) do
    case next_pending_question(task.id) do
      %Question{} = next_question ->
        Pipeline.broadcast_pipeline_changed(%{
          task_id: task.id,
          event: :question_registered,
          question_id: next_question.id
        })

      nil ->
        Pipeline.release_blocked_stage(scope, task)
    end
  end

  defp resolve_question(%Question{} = question), do: question
  defp resolve_question(id) when is_binary(id), do: Repo.get(Question, id)
  defp resolve_question(_other), do: nil
end
