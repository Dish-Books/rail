defmodule Rail.Pipeline.Actions.AnswerQuestions do
  @moduledoc """
  Records the human's answers to the questions a run asked, and hands them back.

  A run ends by asking its whole batch, so the human answers the batch: every answer
  is recorded, and the round goes back to the agent as one message on the run that
  asked. Nothing about the task's stage is decided here — the turn this starts settles
  the stage when it exits, the same as the run that asked did.
  """

  import Ecto.Query
  import Rail.Pipeline.Utils.QuestionQueue
  import Rail.Pipeline.Utils.SendRunMessage

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Runs.Schemas.Run
  alias Rail.Scope

  @doc """
  Answers pending questions and resumes the run that asked them.

  `answers` maps question id to answer text. Returns
  `{:ok, %{task: task, run: run, os_process: os_process}}` once the round is on its
  way back, or `{:ok, %{task: task}}` when questions are still unanswered — the task
  stays parked on the next one.
  """
  def answer_questions(%Scope{} = scope, task_or_id, answers, opts) when is_map(answers) and is_list(opts) do
    with :ok <- authorize_scope(scope),
         %Task{} = task <- resolve_task(task_or_id),
         {:ok, recorded} <- record_answers(task, answers) do
      deliver_or_wait(task, recorded, opts)
    else
      {:error, reason} -> {:error, reason}
      nil -> {:error, :not_found}
    end
  end

  def answer_questions(%Scope{} = scope, task_or_id, answers) do
    answer_questions(scope, task_or_id, answers, [])
  end

  def answer_questions(task_or_id, answers, opts) when is_list(opts) do
    answer_questions(Scope.for_system(), task_or_id, answers, opts)
  end

  def answer_questions(task_or_id, answers) do
    answer_questions(Scope.for_system(), task_or_id, answers, [])
  end

  defp authorize_scope(%Scope{system: true}), do: :ok
  defp authorize_scope(%Scope{user: %{}}), do: :ok
  defp authorize_scope(_scope), do: {:error, :not_authorized}

  defp record_answers(%Task{} = task, answers) do
    now = DateTime.utc_now()

    recorded =
      answers
      |> Enum.map(fn {question_id, answer} -> {Repo.get(Question, question_id), answer} end)
      |> Enum.filter(fn {question, answer} -> answerable?(task, question, answer) end)
      |> Enum.map(fn {question, answer} -> record_one(question, answer, now) end)

    if recorded == [], do: {:error, :no_answers}, else: {:ok, recorded}
  end

  defp answerable?(%Task{id: task_id}, %Question{task_id: task_id, status: :pending}, answer) when is_binary(answer) do
    String.trim(answer) != ""
  end

  defp answerable?(_task, _question, _answer), do: false

  defp record_one(%Question{} = question, answer, now) do
    {:ok, answered} =
      question
      |> Question.changeset(%{answer: String.trim(answer), status: :answered, answered_at: now})
      |> Repo.update()

    answered
  end

  # Whatever is still pending keeps the task parked: the agent hears back once, with
  # the whole round, not once per answer.
  defp deliver_or_wait(%Task{} = task, _recorded, opts) do
    case next_pending_question(task.id) do
      %Question{} = next -> park_on(task, next)
      nil -> deliver(task, opts)
    end
  end

  defp park_on(%Task{} = task, %Question{} = next) do
    {:ok, task} =
      task
      |> Task.changeset(%{stage_state: :blocked, question_id: next.id})
      |> Repo.update()

    Pipeline.broadcast_pipeline_changed(%{
      task_id: task.id,
      event: :question_registered,
      question_id: next.id
    })

    {:ok, %{task: task}}
  end

  defp deliver(%Task{} = task, opts) do
    {:ok, task} = task |> Task.changeset(%{question_id: nil}) |> Repo.update()

    delivered = undelivered_answers(task.id)

    case run_that_asked(task, delivered) do
      %Run{} = run ->
        mark_delivered(delivered)

        delivered
        |> format_answers()
        |> then(&send_run_message(run, &1, opts))

      nil ->
        {:error, :no_run}
    end
  end

  # A question carries the role that asked it, and a task has one run per role.
  defp run_that_asked(%Task{id: task_id}, questions) do
    questions
    |> Enum.reverse()
    |> Enum.find_value(fn %Question{role_id: role_id} ->
      role_id && Repo.one(from r in Run, where: r.task_id == ^task_id and r.role_id == ^role_id)
    end)
  end

  defp resolve_task(%Task{} = task), do: task
  defp resolve_task(id) when is_binary(id), do: Repo.get(Task, id)
  defp resolve_task(_other), do: nil
end
