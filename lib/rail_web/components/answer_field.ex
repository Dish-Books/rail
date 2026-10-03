defmodule RailWeb.Components.AnswerField do
  @moduledoc """
  Renders the question card for a run's unsent round: one tab per question, open, answered or dismissed.

  Saved answers stay on the card and can be changed until Send answers hands the round back.
  """
  use RailWeb, :html

  attr :question, :any, required: true
  attr :questions, :list, default: []
  attr :answer_text, :string, default: ""
  attr :changing_answer, :boolean, default: false
  attr :role_name, :string, required: true
  attr :submitting, :boolean, default: false
  attr :target, :any, default: nil

  def answer_field(assigns) do
    question = assigns.question
    options = get_field(question, :options) || []
    context_summary = get_field(question, :context_summary)
    questions = if assigns.questions == [], do: [question], else: assigns.questions
    status = status_of(question)
    changing? = assigns.changing_answer
    open_count = Enum.count(questions, &(status_of(&1) == :pending))
    all_dismissed? = Enum.all?(questions, &(status_of(&1) == :dismissed))
    {status_label, status_icon, status_class} = calculate_status_line(status, changing?, all_dismissed?)

    dismissed_note =
      if all_dismissed?,
        do: "Every question in this round is dismissed, so #{assigns.role_name} won't get a message about it.",
        else: "#{assigns.role_name} will carry on without an answer to this."

    assigns =
      assigns
      |> assign(:options, options)
      |> assign(:context_summary, context_summary)
      |> assign(:questions, questions)
      |> assign(:selected_id, get_field(question, :id))
      |> assign(:tabs, questions |> Enum.with_index(1) |> Enum.map(&calculate_tab/1))
      |> assign(:status_label, status_label)
      |> assign(:status_icon, status_icon)
      |> assign(:status_class, status_class)
      |> assign(:show_form?, status == :pending or changing?)
      |> assign(:show_saved_answer?, status == :answered and not changing?)
      |> assign(:show_dismissed_note?, status == :dismissed and not changing?)
      |> assign(:show_cancel?, status != :pending)
      |> assign(:dismissed_note, dismissed_note)
      |> assign(:pending_note, calculate_pending_note(open_count, changing?))
      |> assign(:send_blocked?, open_count > 0 or changing?)
      |> assign(:all_dismissed?, all_dismissed?)

    ~H"""
    <div
      id="answer-field-card"
      data-qa="answer-field"
      class="p-5 rounded-xl border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-900 shadow-xs space-y-4"
    >
      <!-- One tab per question in the unsent round, each marked with where it stands -->
      <div
        :if={length(@questions) > 1}
        id="question-tabs"
        data-qa="question-tabs"
        phx-hook="ScrollSelectedTab"
        role="tablist"
        class="flex items-center gap-1 -mt-1 overflow-x-auto overflow-y-hidden border-b border-slate-200 dark:border-slate-700"
      >
        <button
          :for={{tab, idx} <- Enum.with_index(@tabs)}
          type="button"
          role="tab"
          id={"question-tab-#{idx}"}
          data-qa={"question-tab-#{idx}"}
          aria-selected={to_string(tab.id == @selected_id)}
          aria-label={tab.aria_label}
          phx-click="select_question"
          phx-target={@target}
          phx-value-question_id={tab.id}
          class={[
            "inline-flex items-center gap-1.5 shrink-0 px-3 py-1.5 -mb-px text-xs font-semibold border-b-2 transition-colors cursor-pointer",
            tab.id == @selected_id &&
              "border-blue-600 dark:border-blue-500 text-blue-700 dark:text-blue-300",
            tab.id != @selected_id &&
              "border-transparent text-slate-500 dark:text-slate-400 hover:text-slate-900 dark:hover:text-slate-100"
          ]}
        >
          <.icon name={tab.icon} class={["h-3.5 w-3.5", tab.icon_class]} />
          <span>{tab.label}</span>
        </button>
      </div>

      <div>
        <span
          data-qa="question-status"
          class={["inline-flex items-center gap-1 mb-2 text-[11px] font-semibold", @status_class]}
        >
          <.icon name={@status_icon} class="h-[13px] w-[13px]" />
          <span>{@status_label}</span>
        </span>

        <!-- Question Prompt (titleMedium, weight 600) -->
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

      <div :if={@show_saved_answer?}>
        <div class="text-xs font-medium text-slate-500 dark:text-slate-400 mb-1">Your answer</div>
        <div
          id="saved-answer"
          data-qa="saved-answer"
          phx-no-format
          class="px-3 py-2 rounded-xl bg-slate-100 dark:bg-slate-800 border border-slate-200 dark:border-slate-700 text-[13px] leading-relaxed text-slate-800 dark:text-slate-100 whitespace-pre-wrap"
        >{get_field(@question, :answer)}</div>
      </div>

      <div :if={@show_saved_answer?} class="flex items-center justify-end gap-2">
        <button
          type="button"
          id="dismiss-question-button"
          data-qa="dismiss-question-button"
          phx-click="dismiss_question"
          phx-target={@target}
          phx-value-question_id={get_field(@question, :id)}
          class="px-3 py-1.5 rounded-lg text-xs font-semibold text-slate-500 dark:text-slate-400 hover:text-slate-900 dark:hover:text-slate-100 hover:bg-slate-100 dark:hover:bg-slate-700 transition-colors cursor-pointer"
        >
          Dismiss
        </button>

        <button
          type="button"
          id="change-answer-button"
          data-qa="change-answer-button"
          phx-click="change_answer"
          phx-target={@target}
          class="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-xs font-semibold border border-slate-300 dark:border-slate-600 text-slate-900 dark:text-slate-100 bg-white dark:bg-slate-900 hover:bg-slate-100 dark:hover:bg-slate-800 transition-colors cursor-pointer"
        >
          <.icon name="pi-pencil-simple" class="h-4 w-4 shrink-0" />
          <span>Change answer</span>
        </button>
      </div>

      <p
        :if={@show_dismissed_note?}
        id="dismissed-note"
        data-qa="dismissed-note"
        class="px-3 py-2 rounded-lg bg-slate-100 dark:bg-slate-800 text-xs text-slate-600 dark:text-slate-300"
      >
        {@dismissed_note}
      </p>

      <div :if={@show_dismissed_note?} class="flex justify-end gap-2">
        <button
          type="button"
          id="answer-instead-button"
          data-qa="answer-instead-button"
          phx-click="change_answer"
          phx-target={@target}
          class="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-xs font-semibold border border-slate-300 dark:border-slate-600 text-slate-900 dark:text-slate-100 bg-white dark:bg-slate-900 hover:bg-slate-100 dark:hover:bg-slate-800 transition-colors cursor-pointer"
        >
          <.icon name="pi-pencil-simple" class="h-4 w-4 shrink-0" />
          <span>Answer instead</span>
        </button>
      </div>

      <!-- Option Chips (ActionChips) -->
      <div
        :if={@show_form? and is_list(@options) and @options != []}
        id="question-options"
        data-qa="question-options"
        class="flex flex-wrap gap-2"
      >
        <button
          :for={{option, idx} <- Enum.with_index(@options)}
          type="button"
          id={"question-option-#{idx}"}
          data-qa={"question-option-#{idx}"}
          phx-click="select_option"
          phx-target={@target}
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
        :if={@show_form?}
        id="answer-question-form"
        phx-submit="answer_question"
        phx-change="answer_form_change"
        phx-target={@target}
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
            :if={not @show_cancel?}
            type="button"
            id="dismiss-question-button"
            data-qa="dismiss-question-button"
            phx-click="dismiss_question"
            phx-target={@target}
            phx-value-question_id={get_field(@question, :id)}
            class="px-3 py-1.5 rounded-lg text-xs font-semibold text-slate-500 dark:text-slate-400 hover:text-slate-900 dark:hover:text-slate-100 hover:bg-slate-100 dark:hover:bg-slate-700 transition-colors cursor-pointer"
          >
            Dismiss
          </button>

          <button
            :if={@show_cancel?}
            type="button"
            id="cancel-answer-button"
            data-qa="cancel-answer-button"
            phx-click="cancel_answer"
            phx-target={@target}
            class="px-3 py-1.5 rounded-lg text-xs font-semibold text-slate-500 dark:text-slate-400 hover:text-slate-900 dark:hover:text-slate-100 hover:bg-slate-100 dark:hover:bg-slate-700 transition-colors cursor-pointer"
          >
            Cancel
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
      <div class="flex items-center justify-between gap-2 pt-3 border-t border-slate-200 dark:border-slate-700">
        <span
          :if={@pending_note != nil}
          data-qa="questions-pending-note"
          class="text-xs text-slate-500 dark:text-slate-400"
        >
          {@pending_note}
        </span>

        <button
          :if={not @all_dismissed?}
          type="button"
          id="send-answers-button"
          data-qa="send-answers-button"
          phx-click="send_answers"
          phx-target={@target}
          disabled={@send_blocked?}
          class="ml-auto inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-xs font-semibold bg-blue-600 dark:bg-blue-500 text-white hover:opacity-90 transition-opacity shadow-xs cursor-pointer disabled:opacity-50 disabled:cursor-not-allowed"
        >
          <.icon name="pi-paper-plane-tilt" class="h-4 w-4 shrink-0" />
          <span>Send answers</span>
        </button>

        <!-- With nothing answered there is nothing to send, so the round closes without a message. -->
        <button
          :if={@all_dismissed?}
          type="button"
          id="dismiss-questions-button"
          data-qa="dismiss-questions-button"
          phx-click="dismiss_round"
          phx-target={@target}
          disabled={@send_blocked?}
          class="ml-auto inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-xs font-semibold border border-slate-300 dark:border-slate-600 text-slate-900 dark:text-slate-100 bg-white dark:bg-slate-900 hover:bg-slate-100 dark:hover:bg-slate-800 transition-colors cursor-pointer disabled:opacity-50 disabled:cursor-not-allowed"
        >
          <.icon name="pi-x-circle" class="h-4 w-4 shrink-0" />
          <span>Dismiss questions</span>
        </button>
      </div>
    </div>
    """
  end

  defp calculate_tab({question, number}) do
    {icon, icon_class, words} =
      case status_of(question) do
        :answered -> {"pi-check-circle-fill", "text-emerald-500 dark:text-emerald-400", "answered"}
        :dismissed -> {"pi-minus-circle", "text-slate-400", "dismissed"}
        :pending -> {"pi-circle-bold", "text-amber-500 dark:text-amber-400", "not answered yet"}
      end

    %{
      id: get_field(question, :id),
      label: "Question #{number}",
      aria_label: "Question #{number}, #{words}",
      icon: icon,
      icon_class: icon_class
    }
  end

  # An unsaved change on screen would otherwise go out as the answer it was replacing.
  defp calculate_pending_note(_open_count, true), do: "Save or cancel your change first"
  defp calculate_pending_note(0, false), do: nil
  defp calculate_pending_note(open_count, false), do: "#{open_count} still to answer"

  defp calculate_status_line(:pending, _changing?, _all_dismissed?) do
    {"Not answered yet", "pi-circle-bold", "text-amber-700 dark:text-amber-300"}
  end

  defp calculate_status_line(:answered, changing?, _all_dismissed?) do
    label = if changing?, do: "Answered · changing your answer", else: "Answered · not sent yet"
    {label, "pi-check-circle-fill", "text-emerald-700 dark:text-emerald-300"}
  end

  defp calculate_status_line(:dismissed, changing?, all_dismissed?) do
    label =
      cond do
        changing? -> "Dismissed · answering instead"
        all_dismissed? -> "Dismissed"
        true -> "Dismissed · not sent yet"
      end

    {label, "pi-minus-circle", "text-slate-500 dark:text-slate-400"}
  end

  # A question built before it is saved, or a bare map, has no status yet and is still open.
  defp status_of(question), do: get_field(question, :status) || :pending

  defp get_field(%_struct{} = struct, field), do: Map.get(struct, field)
  defp get_field(map, field) when is_map(map), do: Map.get(map, field) || Map.get(map, to_string(field))
  defp get_field(_other, _field), do: nil
end
