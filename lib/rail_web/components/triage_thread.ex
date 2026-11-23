defmodule RailWeb.Components.TriageThread do
  @moduledoc """
  The Slack thread or Intercom conversation of a triage page, each passage marked by the item it raised.
  """
  use RailWeb, :html

  alias Rail.Triage.Schemas.Item
  alias Rail.Triage.Schemas.Message
  alias Rail.Triage.Schemas.Thread
  alias RailWeb.Components.TriageVerdict

  attr :thread, Thread, required: true

  def triage_thread(assigns) do
    items = assigns.thread.items
    by_key = Map.new(items, &{&1.key, &1})

    assigns =
      assigns
      |> assign(:messages, Enum.map(assigns.thread.messages, &message(&1, items, by_key)))
      |> assign(:forwarded, Thread.forwarded?(assigns.thread))

    ~H"""
    <section id="triage-thread" data-qa="triage-thread" class="flex-1 flex flex-col min-h-0">
      <div class="flex-1 min-h-0 overflow-y-auto px-3 py-3 space-y-1.5">
        <div
          :for={entry <- @messages}
          id={"triage-message-#{entry.message.id}"}
          data-qa="triage-message"
          class={["flex gap-2.5 rounded-lg pl-2 pr-2.5 py-2 border-l-[3px]", entry.border]}
        >
          <span
            :if={!entry.message.from_bot}
            class="flex items-center justify-center h-7 w-7 rounded-full shrink-0 bg-indigo-500 text-white text-[10px] font-semibold"
          >
            {entry.initials}
          </span>
          <span
            :if={entry.message.from_bot}
            class="flex items-center justify-center h-7 w-7 rounded-lg shrink-0 bg-blue-100 dark:bg-blue-900 text-blue-800 dark:text-blue-200"
          >
            <.icon name="pi-robot" class="size-4" />
          </span>
          <div class="min-w-0">
            <p class="text-[13px] text-slate-900 dark:text-slate-100">
              <span class="font-semibold">{entry.message.author_name}</span>
              <span
                :if={entry.message.from_bot}
                class="px-1 rounded text-[10px] font-semibold bg-slate-200 dark:bg-slate-700 text-slate-600 dark:text-slate-300"
              >
                APP
              </span>
              <span
                :if={entry.via_rail}
                data-qa="via-rail"
                class="px-1 rounded text-[10px] font-semibold bg-blue-100 dark:bg-blue-900 text-blue-800 dark:text-blue-200"
              >
                via Rail
              </span>
              <.local_time
                id={"message-time-#{entry.message.id}"}
                at={entry.message.posted_at}
                class="text-xs text-slate-500 dark:text-slate-400"
              />
            </p>
            <p class="text-[13px] leading-relaxed text-slate-800 dark:text-slate-200 whitespace-pre-line break-words">
              <span :for={{text, mark} <- entry.segments}><mark
                :if={mark}
                class={["text-inherit rounded px-0.5", mark]}
              >{text}</mark><span :if={!mark}>{text}</span></span>
            </p>
            <div
              :if={entry.message.images != []}
              id={"triage-images-#{entry.message.id}"}
              class="mt-2 flex flex-wrap gap-2"
            >
              <.triage_image
                :for={image <- entry.message.images}
                message_id={entry.message.id}
                image={image}
              />
            </div>
            <p :if={entry.chips != []} class="mt-1 flex flex-wrap items-center gap-1.5">
              <span
                :for={chip <- entry.chips}
                class={[
                  "px-1.5 rounded text-[11px] font-bold",
                  TriageVerdict.kind_style(chip.item.kind).class
                ]}
              >
                {chip.item.position} {Item.kind_label(chip.item.kind)}
              </span>
              <span :for={note <- entry.notes} class="text-[11px] text-slate-500 dark:text-slate-400">{note}</span>
            </p>
            <p
              :if={entry.message.no_response_reason}
              title={entry.message.no_response_reason}
              class="mt-1 inline-flex items-center gap-1 text-[11px] text-slate-500 dark:text-slate-400"
            >
              <.icon name="pi-minus-circle" class="size-3" />Needs no response. Nothing drafted.
            </p>
          </div>
        </div>
      </div>
      <div
        :if={@thread.permalink}
        class="px-4 py-2.5 border-t border-slate-200 dark:border-slate-700 text-xs"
      >
        <a
          href={@thread.permalink}
          target="_blank"
          rel="noopener noreferrer"
          id="open-in-slack"
          class="inline-flex items-center gap-1 font-semibold text-blue-600 dark:text-blue-400 rounded focus-visible:outline-2 focus-visible:outline-blue-500"
        >
          <.icon :if={!@forwarded} name="pi-slack-logo" class="size-3.5" />
          <.icon :if={@forwarded} name="pi-arrow-square-out" class="size-3.5" />
          {if @forwarded, do: "Open in Intercom", else: "Open in Slack"}
        </a>
      </div>
    </section>
    """
  end

  defp message(%Message{} = message, items, by_key) do
    linked = for link <- message.item_links, item = by_key[link.item_key], do: {link, item}
    kinds = Map.new(items, &{&1.position, &1.kind})

    %{
      message: message,
      via_rail: Message.via_rail?(message),
      initials: initials(message.author_name),
      segments: for({text, position} <- Message.segments(message, items), do: {text, mark_class(kinds[position])}),
      chips: linked |> Enum.map(fn {_link, item} -> %{item: item} end) |> Enum.uniq_by(& &1.item.id),
      notes: for({link, item} <- linked, link.change != :raised, do: "#{link.change} item #{item.position}"),
      border: border(message, linked)
    }
  end

  defp mark_class(:bug), do: "bg-red-500/15"
  defp mark_class(:feature_request), do: "bg-violet-500/15"
  defp mark_class(nil), do: nil

  defp border(%Message{no_response_reason: reason}, []) when is_binary(reason),
    do: "border-dashed border-slate-300 dark:border-slate-600"

  defp border(_message, []), do: "border-transparent"

  defp border(_message, [{_link, %Item{kind: kind}} | _rest]),
    do:
      Map.fetch!(%{bug: "border-red-500", feature_request: "border-violet-500"}, kind) <>
        " bg-slate-50 dark:bg-slate-800/40"

  defp initials(name) when is_binary(name) do
    name |> String.split(~r/\s+/, trim: true) |> Enum.take(2) |> Enum.map_join(&String.first/1) |> String.upcase()
  end
end
