defmodule Rail.Pipeline.Actions.AnswerQuestion do
  @moduledoc """
  Action that records a human answer for a pending agent question.
  Marks the question as `:answered` and terminates running execution (if active and
  not rebasing).

  A run that asked several things leaves a queue behind it. Answering one question
  moves the next to the front and the task stays blocked, so the human works through
  them without the stage restarting in between. Only when nothing is pending does the
  stage re-queue, via `Rail.Pipeline.request_changes/4`, carrying every answer of the
  round at once.
  """

  import Rail.Pipeline.Utils.QuestionQueue

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
      Runs.stop_os_process(task.id)
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

    case next_pending_question(task.id) do
      %Question{} = next_question ->
        advance_queue(task, next_question, updated_question)

      nil ->
        resume_stage(scope, task, updated_question)
    end
  end

  # More questions are waiting: keep the stage parked and put the next one in front.
  defp advance_queue(%Task{} = task, %Question{} = next_question, answered) do
    {:ok, updated_task} =
      task
      |> Task.changeset(%{stage_state: :blocked, question_id: next_question.id})
      |> Repo.update()

    Pipeline.broadcast_pipeline_changed(%{
      task_id: updated_task.id,
      event: :question_registered,
      question_id: next_question.id
    })

    {:ok, answered}
  end

  defp resume_stage(scope, %Task{} = task, answered) do
    {:ok, task_cleared} =
      task
      |> Task.changeset(%{question_id: nil})
      |> Repo.update()

    delivered = undelivered_answers(task.id)
    comment = format_answers(delivered)

    with {:ok, _task} <- Pipeline.request_changes(scope, task_cleared, comment) do
      mark_delivered(delivered)
      {:ok, answered}
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
