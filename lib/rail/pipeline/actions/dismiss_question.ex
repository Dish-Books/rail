defmodule Rail.Pipeline.Actions.DismissQuestion do
  @moduledoc """
  Action that dismisses a pending agent question.
  Updates the question status to `:dismissed`, and if the task was parked on this question,
  releases the blocked stage via `Rail.Pipeline.release_blocked_stage/2`.
  """

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
      %Task{question_id: q_id} = task when q_id == updated_question.id ->
        Pipeline.release_blocked_stage(scope, task)
        {:ok, updated_question}

      _other ->
        {:ok, updated_question}
    end
  end

  defp resolve_question(%Question{} = question), do: question
  defp resolve_question(id) when is_binary(id), do: Repo.get(Question, id)
  defp resolve_question(_other), do: nil
end
