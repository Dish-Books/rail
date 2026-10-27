defmodule RailWeb.Components.AnswerField do
  @moduledoc """
  Renders a run's unsent round in the composer's place: a numbered chip per question and one answer box.

  The box holds whatever the open question has, its saved answer, Rail's or a likely past one, and nothing is saved
  until its check. Send answers shows once no question is open and the box holds nothing unsaved.
  """
  use RailWeb, :html

  attr :question, :any, required: true
  attr :questions, :list, default: []
  attr :suggestions, :map, default: %{}, doc: "question id to the past answer matched to it"
  attr :answer_text, :string, default: ""
  attr :target, :any, default: nil

  def answer_field(assigns) do
    question = assigns.question
    questions = if assigns.questions == [], do: [question], else: assigns.questions
    status = status_of(question)
    unsaved? = String.trim(assigns.answer_text) != (get_field(question, :answer) || "")
    all_dismissed? = Enum.all?(questions, &(status_of(&1) == :dismissed))
    settled? = not Enum.any?(questions, &(status_of(&1) == :pending)) and not unsaved?

    assigns =
      assigns
      |> assign(:options, get_field(question, :options) || [])
      |> assign(:selected_id, get_field(question, :id))
      |> assign(:chips, questions |> Enum.with_index(1) |> Enum.map(&calculate_chip/1))
      |> assign(:meta, calculate_meta(question, status, Map.get(assigns.suggestions, get_field(question, :id))))
      |> assign(:show_dismiss?, status != :dismissed)
      |> assign(:show_send?, settled? and not all_dismissed?)
      |> assign(:show_dismiss_round?, settled? and all_dismissed?)

    ~H"""
    <div class="flex items-center gap-1 min-w-0">
      <div
        id="question-tabs"
        data-qa="question-tabs"
        phx-hook="ScrollSelectedTab"
        role="tablist"
        aria-label="Questions"
        class="flex items-center gap-1 min-w-0 overflow-x-auto overflow-y-hidden"
      >
        <button
          :for={chip <- @chips}
          type="button"
          role="tab"
          id={"question-tab-#{chip.number - 1}"}
          data-qa={"question-tab-#{chip.number - 1}"}
          aria-selected={to_string(chip.id == @selected_id)}
          aria-label={chip.aria_label}
          phx-click="select_question"
          phx-target={@target}
          phx-value-question_id={chip.id}
          class={[
            "inline-flex items-center gap-1 h-7 px-2 shrink-0 rounded-md border text-xs font-semibold cursor-pointer",
            chip.id == @selected_id &&
              "border-blue-600 dark:border-blue-500 bg-blue-50 dark:bg-blue-950/50 text-blue-800 dark:text-blue-200",
            chip.id != @selected_id &&
              "border-slate-300 dark:border-slate-600 text-slate-700 dark:text-slate-200 hover:bg-slate-100 dark:hover:bg-slate-800"
          ]}
        >
          <.icon name={chip.icon} class={["size-[13px] shrink-0", chip.icon_class]} />
          <span>{chip.number}</span>
        </button>
      </div>
      <span class="ml-auto" />
      <button
        :if={@show_dismiss?}
        type="button"
        id="dismiss-question-button"
        data-qa="dismiss-question-button"
        phx-click="dismiss_question"
        phx-target={@target}
        phx-value-question_id={@selected_id}
        class="inline-flex items-center gap-1 px-2 py-1 shrink-0 rounded-lg text-xs font-semibold text-slate-500 dark:text-slate-400 hover:text-slate-900 dark:hover:text-slate-100 hover:bg-slate-100 dark:hover:bg-slate-700 cursor-pointer"
      >
        Dismiss
      </button>
      <!-- Nothing reaches the agent until the human says the round is done. -->
      <button
        :if={@show_send?}
        type="button"
        id="send-answers-button"
        data-qa="send-answers-button"
        phx-click="send_answers"
        phx-target={@target}
        class="inline-flex items-center gap-1.5 px-3 py-1.5 shrink-0 rounded-lg text-xs font-semibold bg-blue-600 dark:bg-blue-500 text-white hover:opacity-90 shadow-xs cursor-pointer"
      >
        <.icon name="pi-paper-plane-tilt" class="h-4 w-4 shrink-0" />Send answers
      </button>
      <!-- With nothing answered there is nothing to send, so the round closes without a message. -->
      <button
        :if={@show_dismiss_round?}
        type="button"
        id="dismiss-questions-button"
        data-qa="dismiss-questions-button"
        phx-click="dismiss_round"
        phx-target={@target}
        class="inline-flex items-center gap-1.5 py-1.5 px-3 shrink-0 rounded-lg text-xs font-semibold border border-slate-300 dark:border-slate-600 text-slate-900 dark:text-slate-100 bg-white dark:bg-slate-900 hover:bg-slate-100 dark:hover:bg-slate-800 cursor-pointer"
      >
        <.icon name="pi-x-circle" class="h-4 w-4 shrink-0" />Dismiss questions
      </button>
    </div>

    <div class="space-y-1">
      <h3
        id="question-prompt"
        data-qa="question-prompt"
        class="text-[13.5px] font-semibold leading-snug text-slate-900 dark:text-slate-100 wrap-break-word"
      >
        {get_field(@question, :prompt)}
      </h3>
      <p
        :if={@meta}
        id="question-meta"
        data-qa="question-meta"
        class="flex items-center gap-1 min-w-0 text-[11px] text-slate-500 dark:text-slate-400"
      >
        <.icon name={@meta.icon} class={["size-3 shrink-0", @meta.icon_class]} />
        <span phx-no-format class="min-w-0 wrap-break-word">{@meta.before}<.link
            :if={@meta.task_id}
            navigate={~p"/tasks/#{@meta.task_id}"}
            class="font-mono text-blue-600 dark:text-blue-400 hover:underline"
          >{@meta.identifier}</.link><span :if={!@meta.task_id} class="font-mono">{@meta.identifier}</span>{@meta.after}</span>
      </p>
    </div>

    <div
      :if={@options != []}
      id="question-options"
      data-qa="question-options"
      class="flex flex-wrap gap-1.5"
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
          "inline-flex items-center gap-1 max-w-full px-2.5 py-1.5 rounded-lg text-xs font-semibold text-left border cursor-pointer",
          @answer_text == option &&
            "bg-blue-100 dark:bg-blue-900 text-blue-800 dark:text-blue-200 border-blue-600 dark:border-blue-500",
          @answer_text != option &&
            "bg-slate-100 dark:bg-slate-700 text-slate-900 dark:text-slate-100 border-slate-300 dark:border-slate-600 hover:bg-slate-200 dark:hover:bg-slate-600"
        ]}
      >
        <span class="min-w-0 wrap-break-word">{option}</span>
        <span
          :if={idx == 0}
          data-qa="recommended"
          class="inline-flex items-center gap-0.5 shrink-0 ml-1 text-[10px] font-semibold text-indigo-700 dark:text-indigo-300"
        >
          <.icon name="pi-thumbs-up-fill" class="size-2.5" />Recommended
        </span>
      </button>
    </div>

    <form
      id="answer-question-form"
      phx-submit="answer_question"
      phx-change="answer_form_change"
      phx-target={@target}
      class="flex items-end gap-2"
    >
      <input type="hidden" name="question_id" value={@selected_id} />
      <%!-- Kept on one line: a textarea renders the template's own indentation. --%>
      <textarea
        id="answer-textarea"
        name="answer"
        data-qa="answer-textarea"
        rows="1"
        aria-label="Answer"
        placeholder="Type your answer..."
        phx-no-format
        class="flex-1 min-w-0 resize-none field-sizing-content max-h-40 px-3 py-2 text-sm rounded-lg border border-slate-500 dark:border-slate-400 bg-white dark:bg-slate-900 text-slate-900 dark:text-slate-100 placeholder-slate-500 dark:placeholder-slate-400 focus:outline-none focus:ring-1 focus:ring-blue-600 dark:focus:ring-blue-500"
      >{@answer_text}</textarea>
      <button
        type="submit"
        id="save-answer-button"
        data-qa="save-answer-button"
        aria-label="Save answer"
        title="Save answer"
        class="inline-flex items-center justify-center h-9 w-9 shrink-0 rounded-lg bg-blue-600 dark:bg-blue-500 text-white hover:opacity-90 shadow-xs cursor-pointer"
      >
        <.icon name="pi-check-bold" class="h-4 w-4" />
      </button>
    </form>
    """
  end

  defp calculate_chip({question, number}) do
    {icon, icon_class, words} =
      case {status_of(question), get_field(question, :answered_by_rail) == true} do
        {:answered, true} -> {"pi-robot-fill", "text-emerald-600 dark:text-emerald-400", "answered by Rail"}
        {:answered, false} -> {"pi-check-circle-fill", "text-emerald-500 dark:text-emerald-400", "answered"}
        {:dismissed, _by_rail} -> {"pi-minus-circle", "text-slate-400", "dismissed"}
        {:pending, _by_rail} -> {"pi-circle-bold", "text-amber-500 dark:text-amber-400", "not answered yet"}
      end

    %{
      id: get_field(question, :id),
      number: number,
      aria_label: "Question #{number}, #{words}",
      icon: icon,
      icon_class: icon_class
    }
  end

  # The one line under the prompt says whose answer the box starts from; a person's own needs no line.
  defp calculate_meta(question, :answered, source) do
    if get_field(question, :answered_by_rail) == true do
      Map.merge(
        %{icon: "pi-robot-fill", icon_class: "text-emerald-600 dark:text-emerald-400"},
        calculate_said("Rail answered from", source)
      )
    end
  end

  defp calculate_meta(_question, :pending, %{} = source),
    do: Map.merge(%{icon: "pi-clock-counter-clockwise", icon_class: nil}, calculate_said("Likely answer, from", source))

  defp calculate_meta(_question, :dismissed, _source),
    do: %{icon: "pi-minus-circle", icon_class: nil, before: "Dismissed", identifier: nil, task_id: nil, after: nil}

  defp calculate_meta(_question, :pending, nil), do: nil

  # Split around the issue it names, which links to the task it was answered on.
  defp calculate_said(lead, nil), do: %{before: "#{lead} a past answer", identifier: nil, task_id: nil, after: nil}

  defp calculate_said(lead, %{identifier: nil} = source),
    do: %{before: "#{lead} #{source.by}, #{date(source)}", identifier: nil, task_id: nil, after: nil}

  defp calculate_said(lead, source) do
    %{
      before: "#{lead} #{source.by} on ",
      identifier: source.identifier,
      task_id: source.task_id,
      after: ", #{date(source)}"
    }
  end

  defp date(%{date: date}), do: Calendar.strftime(date, "%b %-d")

  # A question built before it is saved, or a bare map, has no status yet and is still open.
  defp status_of(question), do: get_field(question, :status) || :pending

  defp get_field(%_struct{} = struct, field), do: Map.get(struct, field)
  defp get_field(map, field) when is_map(map), do: Map.get(map, field) || Map.get(map, to_string(field))
  defp get_field(_other, _field), do: nil
end
