defmodule RailWeb.Components.AnswerField do
  @moduledoc """
  Renders the AnswerField card on the Overview tab for a pending agent question.
  Per spec 05 §5, displays the question prompt, context summary, option chips,
  and a textarea with Dismiss and Answer & resume actions.

  A run that asked several things leaves them all pending at once. They render as
  tabs across the top of the one card, so the human answers them one at a time
  without leaving the task: the stage stays parked until the last one is resolved.
  """
  use RailWeb, :html

  import RailWeb.CoreComponents, only: [icon: 1]

  attr :question, :any, required: true
  attr :questions, :list, default: []
  attr :answer_text, :string, default: ""
  attr :submitting, :boolean, default: false

  def answer_field(assigns) do
    question = assigns.question
    options = get_field(question, :options) || []
    context_summary = get_field(question, :context_summary)
    questions = if assigns.questions == [], do: [question], else: assigns.questions

    assigns =
      assigns
      |> assign(:options, options)
      |> assign(:context_summary, context_summary)
      |> assign(:questions, questions)
      |> assign(:selected_id, get_field(question, :id))

    ~H"""
    <div
      id="answer-field-card"
      data-qa="answer-field"
      class="p-5 rounded-xl border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-900 shadow-xs space-y-4"
    >
      <!-- One tab per question the run asked; the stage stays parked until all are resolved -->
      <div
        :if={length(@questions) > 1}
        id="question-tabs"
        data-qa="question-tabs"
        role="tablist"
        class="flex items-center gap-1 -mt-1 overflow-x-auto border-b border-slate-200 dark:border-slate-700"
      >
        <button
          :for={{tab, idx} <- Enum.with_index(@questions)}
          type="button"
          role="tab"
          id={"question-tab-#{idx}"}
          data-qa={"question-tab-#{idx}"}
          aria-selected={to_string(get_field(tab, :id) == @selected_id)}
          phx-click="select_question"
          phx-value-question_id={get_field(tab, :id)}
          class={[
            "shrink-0 px-3 py-1.5 -mb-px text-xs font-semibold border-b-2 transition-colors cursor-pointer",
            get_field(tab, :id) == @selected_id &&
              "border-blue-600 dark:border-blue-500 text-blue-700 dark:text-blue-300",
            get_field(tab, :id) != @selected_id &&
              "border-transparent text-slate-500 dark:text-slate-400 hover:text-slate-900 dark:hover:text-slate-100"
          ]}
        >
          Question {idx + 1}
        </button>

        <span
          data-qa="question-tabs-remaining"
          class="ml-auto pl-3 pr-1 text-xs text-slate-500 dark:text-slate-400 shrink-0"
        >
          {length(@questions)} unanswered
        </span>
      </div>

      <!-- Question Prompt (titleMedium, weight 600) -->
      <div>
        <h3
          id="question-prompt"
          data-qa="question-prompt"
          class="text-base font-semibold text-slate-900 dark:text-slate-100 leading-snug"
        >
          {get_field(@question, :prompt)}
        </h3>

        <!-- Context Summary (bodySmall in outline) -->
        <p
          :if={is_binary(@context_summary) and @context_summary != ""}
          id="question-context-summary"
          data-qa="question-context-summary"
          class="text-xs text-slate-500 dark:text-slate-400 mt-1"
        >
          {@context_summary}
        </p>
      </div>

      <!-- Option Chips (ActionChips) -->
      <div
        :if={is_list(@options) and @options != []}
        id="question-options"
        data-qa="question-options"
        class="flex flex-wrap gap-2 my-3"
      >
        <button
          :for={{option, idx} <- Enum.with_index(@options)}
          type="button"
          id={"question-option-#{idx}"}
          data-qa={"question-option-#{idx}"}
          phx-click="select_option"
          phx-value-option={option}
          class={[
            "px-3 py-1.5 rounded-lg text-xs font-semibold transition-colors cursor-pointer border",
            @answer_text == option &&
              "bg-blue-100 dark:bg-blue-900 text-blue-800 dark:text-blue-200 border-blue-600 dark:border-blue-500",
            @answer_text != option &&
              "bg-slate-100 dark:bg-slate-700 text-slate-900 dark:text-slate-100 border-slate-300 dark:border-slate-600 hover:bg-slate-200 dark:hover:bg-slate-600"
          ]}
        >
          {option}
        </button>
      </div>

      <!-- Textarea & Action Buttons Form -->
      <form
        id="answer-question-form"
        phx-submit="answer_question"
        phx-change="answer_form_change"
        class="space-y-3"
      >
        <input type="hidden" name="question_id" value={get_field(@question, :id)} />

        <div>
          <label
            for="answer-textarea"
            class="block text-xs font-medium text-slate-500 dark:text-slate-400 mb-1"
          >
            Your answer
          </label>
          <textarea
            id="answer-textarea"
            name="answer"
            data-qa="answer-textarea"
            rows="3"
            placeholder="Type your answer..."
            class="w-full px-3 py-2 text-sm rounded-lg border border-slate-500 dark:border-slate-400 bg-white dark:bg-slate-900 text-slate-900 dark:text-slate-100 placeholder-slate-500 dark:placeholder-slate-400 focus:outline-none focus:ring-1 focus:ring-blue-600 dark:focus:ring-blue-500 resize-y min-h-[4rem] max-h-[8rem]"
          >{@answer_text}</textarea>
        </div>

        <div class="flex items-center justify-end gap-2 pt-1">
          <button
            type="button"
            id="dismiss-question-button"
            data-qa="dismiss-question-button"
            phx-click="dismiss_question"
            phx-value-question_id={get_field(@question, :id)}
            class="px-3 py-1.5 rounded-lg text-xs font-semibold text-slate-500 dark:text-slate-400 hover:text-slate-900 dark:hover:text-slate-100 hover:bg-slate-100 dark:hover:bg-slate-700 transition-colors cursor-pointer"
          >
            Dismiss
          </button>

          <button
            type="submit"
            id="answer-resume-button"
            data-qa="answer-resume-button"
            class="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-xs font-semibold bg-blue-600 dark:bg-blue-500 text-white hover:opacity-90 transition-opacity shadow-xs cursor-pointer"
          >
            <.icon name="pi-check" class="h-4 w-4 shrink-0" />
            <span>Save answer</span>
          </button>
        </div>
      </form>

      <!-- Nothing reaches the agent until the human says the round is done. -->
      <div class="flex items-center justify-between gap-2 pt-3 mt-3 border-t border-slate-200 dark:border-slate-700">
        <span
          :if={@questions != []}
          data-qa="questions-pending-note"
          class="text-xs text-slate-500 dark:text-slate-400"
        >
          {length(@questions)} still to answer
        </span>

        <button
          type="button"
          id="send-answers-button"
          data-qa="send-answers-button"
          phx-click="send_answers"
          disabled={@questions != []}
          class="ml-auto inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-xs font-semibold bg-blue-600 dark:bg-blue-500 text-white hover:opacity-90 transition-opacity shadow-xs cursor-pointer disabled:opacity-50 disabled:cursor-not-allowed"
        >
          <.icon name="pi-paper-plane-tilt" class="h-4 w-4 shrink-0" />
          <span>Send answers</span>
        </button>
      </div>
    </div>
    """
  end

  defp get_field(%_struct{} = struct, field), do: Map.get(struct, field)
  defp get_field(map, field) when is_map(map), do: Map.get(map, field) || Map.get(map, to_string(field))
  defp get_field(_other, _field), do: nil
end
