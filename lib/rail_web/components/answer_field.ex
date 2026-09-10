defmodule RailWeb.Components.AnswerField do
  @moduledoc """
  Renders the AnswerField card on the Overview tab for a pending agent question.
  Per spec 05 §5, displays the question prompt, context summary, option chips,
  and a textarea with Dismiss and Answer & resume actions.
  """
  use RailWeb, :html

  import RailWeb.CoreComponents, only: [icon: 1]

  attr :question, :any, required: true
  attr :answer_text, :string, default: ""
  attr :submitting, :boolean, default: false

  def answer_field(assigns) do
    question = assigns.question
    options = get_field(question, :options) || []
    context_summary = get_field(question, :context_summary)

    assigns =
      assigns
      |> assign(:options, options)
      |> assign(:context_summary, context_summary)

    ~H"""
    <div
      id="answer-field-card"
      data-qa="answer-field"
      class="p-5 rounded-xl border border-[var(--color-border)] bg-[var(--color-surface)] shadow-xs space-y-4"
    >
      <!-- Question Prompt (titleMedium, weight 600) -->
      <div>
        <h3
          id="question-prompt"
          data-qa="question-prompt"
          class="text-base font-semibold text-[var(--color-on-surface)] leading-snug"
        >
          {get_field(@question, :prompt)}
        </h3>

        <!-- Context Summary (bodySmall in outline) -->
        <p
          :if={is_binary(@context_summary) and @context_summary != ""}
          id="question-context-summary"
          data-qa="question-context-summary"
          class="text-xs text-[var(--color-outline)] mt-1"
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
              "bg-[var(--color-primary-container)] text-[var(--color-on-primary-container)] border-[var(--color-primary)]",
            @answer_text != option &&
              "bg-[var(--color-surface-container-high)] text-[var(--color-on-surface)] border-[var(--color-outline-variant)] hover:bg-[var(--color-surface-container-highest)]"
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
            class="block text-xs font-medium text-[var(--color-outline)] mb-1"
          >
            Your answer
          </label>
          <textarea
            id="answer-textarea"
            name="answer"
            data-qa="answer-textarea"
            rows="3"
            placeholder="Type your answer..."
            class="w-full px-3 py-2 text-sm rounded-lg border border-[var(--color-outline)] bg-[var(--color-surface)] text-[var(--color-on-surface)] placeholder-[var(--color-outline)] focus:outline-none focus:ring-1 focus:ring-[var(--color-primary)] resize-y min-h-[4rem] max-h-[8rem]"
          >{@answer_text}</textarea>
        </div>

        <div class="flex items-center justify-end gap-2 pt-1">
          <button
            type="button"
            id="dismiss-question-button"
            data-qa="dismiss-question-button"
            phx-click="dismiss_question"
            phx-value-question_id={get_field(@question, :id)}
            class="px-3 py-1.5 rounded-lg text-xs font-semibold text-[var(--color-outline)] hover:text-[var(--color-on-surface)] hover:bg-[var(--color-surface-container-high)] transition-colors cursor-pointer"
          >
            Dismiss
          </button>

          <button
            type="submit"
            id="answer-resume-button"
            data-qa="answer-resume-button"
            class="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-xs font-semibold bg-[var(--color-primary)] text-[var(--color-on-primary)] hover:opacity-90 transition-opacity shadow-xs cursor-pointer"
          >
            <.icon name="send" class="h-4 w-4 shrink-0" />
            <span>Answer & resume</span>
          </button>
        </div>
      </form>
    </div>
    """
  end

  defp get_field(%_struct{} = struct, field), do: Map.get(struct, field)
  defp get_field(map, field) when is_map(map), do: Map.get(map, field) || Map.get(map, to_string(field))
  defp get_field(_other, _field), do: nil
end
