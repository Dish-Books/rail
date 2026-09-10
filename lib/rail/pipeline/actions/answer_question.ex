defmodule Rail.Pipeline.Actions.AnswerQuestion do
  @moduledoc """
  Action that records a human answer for a pending agent question.
  Marks the question as `:answered`, terminates running execution (if active and not rebasing),
  and re-queues the stage with the formatted answer via `Rail.Pipeline.request_changes/4`.
  """

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Runs
  alias Rail.Scope

  @doc """
  Answers a pending agent question with scope authorization.
  """
  def answer_question(%Scope{} = scope, question_or_id, answer_text) do
    with :ok <- authorize_scope(scope),
         %Question{} = question <- resolve_question(question_or_id),
         {:ok, trimmed_answer} <- validate_answer(answer_text),
         :ok <- validate_pending(question),
         %Task{} = task <- resolve_task(question.task_id) do
      do_answer_question(scope, question, task, trimmed_answer)
    else
      {:error, reason} -> {:error, reason}
      nil -> {:error, :not_found}
    end
  end

  def answer_question(question_or_id, answer_text) do
    answer_question(Scope.for_system(), question_or_id, answer_text)
  end

  defp authorize_scope(%Scope{system: true}), do: :ok
  defp authorize_scope(%Scope{user: %{}}), do: :ok
  defp authorize_scope(_scope), do: {:error, :not_authorized}

  defp validate_answer(answer_text) when is_binary(answer_text) do
    trimmed = String.trim(answer_text)
    if trimmed == "", do: {:error, :empty_answer}, else: {:ok, trimmed}
  end

  defp validate_answer(_other), do: {:error, :empty_answer}

  defp validate_pending(%Question{status: :pending}), do: :ok
  defp validate_pending(%Question{}), do: {:error, :already_resolved}

  defp do_answer_question(scope, %Question{} = question, %Task{} = task, answer_text) do
    if !task.is_rebasing and Runs.is_running?(task.id) do
      Runs.stop_run(task.id)
    end

    now = DateTime.utc_now()

    {:ok, updated_question} =
      question
      |> Question.changeset(%{
        answer: answer_text,
        status: :answered,
        answered_at: now
      })
      |> Repo.update()

    {:ok, task_cleared} =
      task
      |> Task.changeset(%{question_id: nil})
      |> Repo.update()

    comment = "You asked: #{question.prompt}\nThe answer is: #{answer_text}"

    with {:ok, _task} <- Pipeline.request_changes(scope, task_cleared, comment) do
      {:ok, updated_question}
    end
  end

  defp resolve_question(%Question{} = question), do: question
  defp resolve_question(id) when is_binary(id), do: Repo.get(Question, id)
  defp resolve_question(_other), do: nil

  defp resolve_task(id) when is_binary(id) do
    case Repo.get(Task, id) do
      %Task{} = task -> task
      nil -> {:error, :task_not_found}
    end
  end
end
