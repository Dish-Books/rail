defmodule RailWeb.Components.AnswersCard do
  @moduledoc """
  A sent round of answers in the conversation: each question the agent asked beside its answer, from a person or
  from Rail's past answers, which reads apart at a glance.
  """
  use RailWeb, :html

  attr :id, :string, required: true
  attr :sender, :string, required: true
  attr :from, :atom, values: [:person, :rail], required: true
  attr :items, :list, required: true, doc: "the round as `Question.parse_answers_message/2` reads it"

  def answers_card(assigns) do
    assigns = assign(assigns, :count, length(assigns.items))

    ~H"""
    <div
      id={@id}
      data-qa="answers-card"
      data-from={@from}
      class={[
        "ml-auto mt-3.5 w-[92%] px-3 py-2 rounded-xl rounded-br-xs",
        @from == :person &&
          "bg-slate-100 dark:bg-slate-800 border border-slate-200 dark:border-slate-700",
        @from == :rail && "border border-dashed border-slate-400 dark:border-slate-600"
      ]}
    >
      <div
        :if={@from == :person}
        class="flex items-center gap-1 min-w-0 text-[11px] font-semibold text-slate-500 dark:text-slate-400"
      >
        <.icon name="pi-user" class="h-3 w-3 shrink-0" />
        <span data-qa="human-bubble-sender" class="shrink-0 whitespace-nowrap">{@sender}</span>
        <span class="min-w-0 truncate font-normal">
          · {if @count == 1, do: "answer to 1 question", else: "answers to #{@count} questions"}
        </span>
      </div>
      <div
        :if={@from == :rail}
        class="flex items-center gap-1 min-w-0 text-[11px] font-semibold text-slate-600 dark:text-slate-300"
      >
        <.icon name="pi-robot-fill" class="h-3 w-3 shrink-0" />
        <span class="shrink-0">Rail</span>
        <span class="min-w-0 truncate font-normal text-slate-500 dark:text-slate-400">
          · {if @count == 1,
            do: "answered 1 question from a past answer",
            else: "answered #{@count} questions from past answers"}
        </span>
      </div>
      <div class="pt-1">
        <div
          :for={{item, number} <- Enum.with_index(@items, 1)}
          data-qa="answers-card-item"
          class="flex items-start gap-2 px-1.5 py-1"
        >
          <span class={[
            "mt-0.5 size-[18px] shrink-0 grid place-items-center rounded-full text-[10px] font-bold",
            @from == :person && "bg-slate-700 text-white",
            @from == :rail &&
              "border border-slate-400 dark:border-slate-500 text-slate-600 dark:text-slate-300"
          ]}>
            {number}
          </span>
          <div class="min-w-0 flex-1 space-y-0.5">
            <p
              class="text-[11.5px] leading-[16px] text-slate-500 dark:text-slate-400 line-clamp-2 wrap-break-word"
              title={item.question.prompt}
            >
              {item.question.prompt}
            </p>
            <p
              :if={item.question.status == :answered}
              phx-no-format
              class="text-[12.5px] leading-[18px] text-slate-800 dark:text-slate-100 whitespace-pre-wrap wrap-break-word select-text"
            >{item.question.answer}</p>
            <p
              :if={item.question.status == :dismissed}
              data-qa="answers-card-dismissed"
              class="flex items-center gap-1 text-[12.5px] italic text-slate-500 dark:text-slate-400"
            >
              <.icon name="pi-minus-circle" class="h-[13px] w-[13px] shrink-0" />Dismissed
            </p>
            <p
              :if={item.question.answered_by_rail and item.question.status == :answered}
              data-qa="answers-card-citation"
              class="flex items-center gap-1 min-w-0 text-[11px] text-slate-500 dark:text-slate-400"
            >
              <.icon :if={@from == :person} name="pi-robot" class="h-3 w-3 shrink-0" />
              <span class="min-w-0 wrap-break-word">
                {if @from == :person, do: "Rail, from", else: "From"}
                <.citation citation={item.citation} />
              </span>
            </p>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :citation, :map, default: nil

  defp citation(%{citation: nil} = assigns), do: ~H"a past answer"

  defp citation(%{citation: %{identifier: nil}} = assigns), do: ~H"{@citation.by}, {@citation.date}"

  defp citation(assigns) do
    ~H"""
    {@citation.by} on <.link
      navigate={~p"/issues/#{@citation.identifier}"}
      class="font-mono text-blue-600 dark:text-blue-400 hover:underline"
    >{@citation.identifier}</.link>, {@citation.date}
    """
  end
end
