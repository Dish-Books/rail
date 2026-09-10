defmodule RailWeb.Components.QuestionCard do
  @moduledoc false
  use RailWeb, :html

  import RailWeb.CoreComponents, only: [project_badge: 1]

  alias Rail.Domain.Formatters

  attr :row, :any, required: true
  attr :submitting, :boolean, default: false

  def question_card(assigns) do
    row = assigns.row
    question = row.question
    task = row.task
    task_key = task_key(task, question)
    role_name = role_name(task, question)
    header_label = if task_key, do: "#{task_key} · #{role_name}", else: role_name
    elapsed_text = format_elapsed(row.waiting_since)
    started_at = format_started_at(row.waiting_since)
    card_id = item_key_to_id(row.item)

    assigns =
      assigns
      |> assign(:question, question)
      |> assign(:task, task)
      |> assign(:task_key, task_key)
      |> assign(:role_name, role_name)
      |> assign(:header_label, header_label)
      |> assign(:elapsed_text, elapsed_text)
      |> assign(:started_at, started_at)
      |> assign(:card_id, card_id)

    ~H"""
    <div
      id={"question-card-#{@card_id}"}
      data-qa="overview-card question-card"
      class="mb-3 rounded-lg border border-[var(--color-border)] border-l-4 border-l-amber-600 bg-[var(--color-surface)] p-4 shadow-xs"
    >
      <!-- Header Row -->
      <div class="flex items-center justify-between gap-2 mb-3">
        <div class="flex items-center space-x-2 truncate">
          <span
            data-qa="question-chip"
            class="px-2 py-0.5 rounded text-[11px] font-bold bg-amber-100 dark:bg-amber-950 text-amber-900 dark:text-amber-200 shrink-0"
          >
            Question
          </span>

          <.project_badge :if={@task} project={@task.project} />

          <.link
            :if={@task}
            navigate={~p"/tasks/#{@task.id}"}
            id={"question-task-link-#{@card_id}"}
            data-qa="question-task-link"
            class="text-xs font-semibold text-[var(--color-on-surface-variant)] hover:underline truncate"
          >
            {@header_label}
          </.link>

          <span
            :if={is_nil(@task)}
            class="text-xs font-semibold text-[var(--color-on-surface-variant)] truncate"
          >
            {@header_label}
          </span>
        </div>

        <span
          id={"elapsed-#{@card_id}"}
          phx-hook="Elapsed"
          data-started-at={@started_at}
          data-qa="elapsed-text"
          class="text-xs text-[var(--color-outline)] font-mono shrink-0"
        >
          {@elapsed_text}
        </span>
      </div>

      <!-- Question Prompt -->
      <h3
        data-qa="question-prompt"
        class="text-base font-semibold text-[var(--color-on-surface)] leading-snug mb-1"
      >
        {@question.prompt}
      </h3>

      <!-- Context Summary -->
      <p
        :if={is_binary(@question.context_summary) and @question.context_summary != ""}
        data-qa="question-context-summary"
        class="text-xs text-[var(--color-outline)] mb-3"
      >
        {@question.context_summary}
      </p>

      <!-- Option Buttons -->
      <div
        :if={is_list(@question.options) and @question.options != []}
        data-qa="question-options"
        class="flex flex-wrap gap-2 my-3"
      >
        <button
          :for={{option, idx} <- Enum.with_index(@question.options)}
          type="button"
          id={"question-option-#{@card_id}-#{idx}"}
          data-qa={"question-option-#{idx}"}
          phx-click="answer_question"
          phx-value-question_id={@question.id}
          phx-value-answer={option}
          disabled={@submitting}
          class={[
            "px-3 py-1.5 rounded-lg text-xs font-semibold transition-opacity cursor-pointer disabled:opacity-50 disabled:cursor-not-allowed",
            idx == 0 &&
              "bg-[var(--color-primary)] text-[var(--color-on-primary)] hover:opacity-90 shadow-xs",
            idx != 0 &&
              "border border-[var(--color-outline)] text-[var(--color-on-surface)] hover:bg-[var(--color-surface-container-high)]"
          ]}
        >
          {option}
        </button>
      </div>

      <!-- Answer Field & Action Buttons -->
      <form
        id={"answer-form-#{@card_id}"}
        phx-submit="submit_question_answer"
        phx-change="noop"
        class="flex items-center gap-2 mt-3 pt-2 border-t border-[var(--color-border)]"
      >
        <input type="hidden" name="question_id" value={@question.id} />
        <input
          type="text"
          name="answer"
          id={"answer-input-#{@card_id}"}
          data-qa="answer-input"
          placeholder="Type an answer..."
          autocomplete="off"
          class="flex-1 min-w-0 px-3 py-1.5 rounded-lg text-xs border border-[var(--color-outline)] bg-[var(--color-surface)] text-[var(--color-on-surface)] placeholder-[var(--color-outline)] focus:outline-none focus:ring-1 focus:ring-[var(--color-primary)]"
        />
        <button
          type="submit"
          id={"send-answer-#{@card_id}"}
          data-qa="send-answer-button"
          disabled={@submitting}
          class="px-3 py-1.5 rounded-lg bg-[var(--color-primary)] text-[var(--color-on-primary)] hover:opacity-90 text-xs font-semibold cursor-pointer disabled:opacity-50 disabled:cursor-not-allowed shrink-0"
        >
          Send
        </button>
        <button
          type="button"
          id={"dismiss-question-#{@card_id}"}
          data-qa="dismiss-question-button"
          phx-click="dismiss_question"
          phx-value-question_id={@question.id}
          disabled={@submitting}
          class="px-2.5 py-1.5 rounded-lg text-xs text-[var(--color-outline)] hover:text-[var(--color-on-surface)] hover:bg-[var(--color-surface-container-high)] font-semibold cursor-pointer disabled:opacity-50 disabled:cursor-not-allowed shrink-0"
        >
          Dismiss
        </button>
      </form>
    </div>
    """
  end

  defp task_key(%{issue: %{identifier: identifier}}, _question) when is_binary(identifier) and identifier != "",
    do: identifier

  defp task_key(%{id: id}, _question) when is_binary(id) and id != "", do: id
  defp task_key(_task, %{task_id: task_id}) when is_binary(task_id) and task_id != "", do: task_id
  defp task_key(_task, _question), do: nil

  defp role_name(_task, %{role: %{name: name}}) when is_binary(name) and name != "", do: name
  defp role_name(%{stage: stage}, _question) when stage != nil, do: format_role_id(to_string(stage))
  defp role_name(_task, _question), do: "Agent"

  defp format_role_id(other) when is_binary(other) do
    other
    |> String.split("_")
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp format_elapsed(%DateTime{} = dt) do
    secs = max(0, DateTime.diff(DateTime.utc_now(), dt, :second))
    Formatters.format_duration(secs)
  end

  defp format_started_at(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp item_key_to_id(item) do
    key = Rail.Domain.AttentionItem.key(item)
    String.replace(key, ~r/[^a-zA-Z0-9_\-]/, "-")
  end
end
