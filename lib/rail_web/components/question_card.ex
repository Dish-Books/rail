defmodule RailWeb.Components.QuestionCard do
  @moduledoc """
  A run parked on questions, and the answers being gathered for it.

  Answering records and nothing more — the agent is resumed once, with the whole
  round, when the human presses Send answers. That is why every question the run
  asked is on the one card: the human is working through a batch, not replying to
  a message.
  """
  use RailWeb, :html

  import RailWeb.CoreComponents, only: [project_badge: 1]

  alias Rail.Pipeline.Schemas.Question
  alias Rail.Runs.Schemas.Run

  attr :run, :any, required: true
  attr :submitting, :boolean, default: false

  def question_card(assigns) do
    run = assigns.run

    assigns =
      assigns
      |> assign(:task, run.task)
      |> assign(:questions, Enum.sort_by(run.questions, & &1.inserted_at))
      |> assign(:pending_count, Enum.count(run.questions, &(&1.status == :pending)))
      |> assign(:header_label, "#{task_key(run.task)} · #{role_name(run)}")
      |> assign(:elapsed_text, format_elapsed(Run.waiting_since(run)))
      |> assign(:started_at, format_started_at(Run.waiting_since(run)))

    ~H"""
    <div
      id={"question-card-#{@run.id}"}
      data-qa="overview-card question-card"
      class="mb-3 rounded-lg border border-slate-200 dark:border-slate-700 border-l-4 border-l-amber-600 bg-white dark:bg-slate-900 p-4 shadow-xs"
    >
      <div class="flex items-center justify-between gap-2 mb-3">
        <div class="flex items-center space-x-2 truncate">
          <span
            data-qa="question-chip"
            class="px-2 py-0.5 rounded text-[11px] font-bold bg-amber-100 dark:bg-amber-950 text-amber-900 dark:text-amber-200 shrink-0"
          >
            Question
          </span>

          <.project_badge project={@task.project} />

          <.link
            navigate={~p"/tasks/#{@task.id}"}
            id={"question-task-link-#{@run.id}"}
            data-qa="question-task-link"
            class="text-xs font-semibold text-slate-600 dark:text-slate-300 hover:underline truncate"
          >
            {@header_label}
          </.link>
        </div>

        <span
          id={"elapsed-#{@run.id}"}
          phx-hook="Elapsed"
          data-started-at={@started_at}
          data-qa="elapsed-text"
          class="text-xs text-slate-500 dark:text-slate-400 font-mono shrink-0"
        >
          {@elapsed_text}
        </span>
      </div>

      <div
        :for={question <- @questions}
        class="py-2 border-t border-slate-200 dark:border-slate-700 first:border-t-0"
      >
        <h3
          data-qa="question-prompt"
          class="text-base font-semibold text-slate-900 dark:text-slate-100 leading-snug mb-1"
        >
          {question.prompt}
        </h3>

        <p
          :if={is_binary(question.context_summary) and question.context_summary != ""}
          data-qa="question-context-summary"
          class="text-xs text-slate-500 dark:text-slate-400 mb-2"
        >
          {question.context_summary}
        </p>

        <p
          :if={question.status == :answered}
          data-qa="question-answer"
          class="text-xs text-slate-900 dark:text-slate-100"
        >
          {question.answer}
        </p>

        <p
          :if={question.status == :dismissed}
          data-qa="question-dismissed"
          class="text-xs italic text-slate-500 dark:text-slate-400"
        >
          Dismissed without an answer.
        </p>

        <div
          :if={Question.pending?(question.status) and question.options != []}
          data-qa="question-options"
          class="flex flex-wrap gap-2 my-2"
        >
          <button
            :for={{option, idx} <- Enum.with_index(question.options)}
            type="button"
            id={"question-option-#{question.id}-#{idx}"}
            data-qa={"question-option-#{idx}"}
            phx-click="answer_question"
            phx-value-question_id={question.id}
            phx-value-answer={option}
            disabled={@submitting}
            class={[
              "px-3 py-1.5 rounded-lg text-xs font-semibold transition-opacity cursor-pointer disabled:opacity-50 disabled:cursor-not-allowed",
              idx == 0 && "bg-blue-600 dark:bg-blue-500 text-white hover:opacity-90 shadow-xs",
              idx != 0 &&
                "border border-slate-500 dark:border-slate-400 text-slate-900 dark:text-slate-100 hover:bg-slate-100 dark:hover:bg-slate-700"
            ]}
          >
            {option}
          </button>
        </div>

        <form
          :if={Question.pending?(question.status)}
          id={"answer-form-#{question.id}"}
          phx-submit="submit_question_answer"
          phx-change="noop"
          class="flex items-center gap-2 mt-2"
        >
          <input type="hidden" name="question_id" value={question.id} />
          <input
            type="text"
            name="answer"
            id={"answer-input-#{question.id}"}
            data-qa="answer-input"
            placeholder="Type an answer..."
            autocomplete="off"
            class="flex-1 min-w-0 px-3 py-1.5 rounded-lg text-xs border border-slate-500 dark:border-slate-400 bg-white dark:bg-slate-900 text-slate-900 dark:text-slate-100 placeholder-slate-500 dark:placeholder-slate-400 focus:outline-none focus:ring-1 focus:ring-blue-600 dark:focus:ring-blue-500"
          />
          <button
            type="submit"
            id={"save-answer-#{question.id}"}
            data-qa="save-answer-button"
            disabled={@submitting}
            class="px-3 py-1.5 rounded-lg bg-blue-600 dark:bg-blue-500 text-white hover:opacity-90 text-xs font-semibold cursor-pointer disabled:opacity-50 disabled:cursor-not-allowed shrink-0"
          >
            Save
          </button>
          <button
            type="button"
            id={"dismiss-question-#{question.id}"}
            data-qa="dismiss-question-button"
            phx-click="dismiss_question"
            phx-value-question_id={question.id}
            disabled={@submitting}
            class="px-2.5 py-1.5 rounded-lg text-xs text-slate-500 dark:text-slate-400 hover:text-slate-900 dark:hover:text-slate-100 hover:bg-slate-100 dark:hover:bg-slate-700 font-semibold cursor-pointer disabled:opacity-50 disabled:cursor-not-allowed shrink-0"
          >
            Dismiss
          </button>
        </form>
      </div>

      <div class="flex items-center justify-between gap-2 mt-3 pt-2 border-t border-slate-200 dark:border-slate-700">
        <span
          :if={@pending_count > 0}
          data-qa="questions-pending-note"
          class="text-xs text-slate-500 dark:text-slate-400"
        >
          {@pending_count} still to answer
        </span>

        <button
          type="button"
          id={"send-answers-#{@run.id}"}
          data-qa="send-answers-button"
          phx-click="send_answers"
          phx-value-run_id={@run.id}
          disabled={@submitting or @pending_count > 0}
          class="ml-auto px-3 py-1.5 rounded-lg bg-blue-600 dark:bg-blue-500 text-white hover:opacity-90 text-xs font-semibold cursor-pointer disabled:opacity-50 disabled:cursor-not-allowed shrink-0"
        >
          Send answers
        </button>
      </div>
    </div>
    """
  end

  defp task_key(%{issue: %{identifier: identifier}}) when is_binary(identifier) and identifier != "", do: identifier
  defp task_key(%{id: id}), do: id

  defp role_name(%{role: %{name: name}}) when is_binary(name) and name != "", do: name
  defp role_name(_unnamed), do: "Agent"

  defp format_elapsed(%DateTime{} = datetime) do
    DateTime.utc_now() |> DateTime.diff(datetime, :second) |> max(0) |> format_duration()
  end

  defp format_elapsed(_never), do: ""

  defp format_started_at(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp format_started_at(_never), do: nil
end
