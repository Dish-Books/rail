defmodule RailWeb.Components.TriageThread do
  @moduledoc """
  The middle pane of the triage page: the Slack thread, each passage marked by
  the item it raised, and the corrections people have sent triage. Corrections
  go to the next pass and never to Slack.
  """
  use RailWeb, :html

  alias Phoenix.LiveView.JS
  alias Rail.Triage.Schemas.Item
  alias Rail.Triage.Schemas.Message
  alias Rail.Triage.Schemas.Thread
  alias RailWeb.Components.TriageVerdict

  attr :thread, Thread, required: true
  attr :current_user_id, :string, required: true
  attr :correction, :any, required: true, doc: "the correction changeset the form edits"

  def triage_thread(assigns) do
    items = assigns.thread.items
    by_key = Map.new(items, &{&1.key, &1})
    correctable = Enum.reject(items, &(Item.settled?(&1) or &1.retriaging))

    picked =
      Enum.find(correctable, &(&1.id == Ecto.Changeset.get_field(assigns.correction, :item_id))) ||
        List.first(correctable)

    assigns =
      assigns
      |> assign(:messages, Enum.map(assigns.thread.messages, &message(&1, items, by_key)))
      |> assign(:correctable, correctable)
      |> assign(:picked, picked)
      |> assign(:assumption, Ecto.Changeset.get_field(assigns.correction, :assumption))
      |> assign(:corrections, Enum.map(assigns.thread.corrections, &correction(&1, assigns.current_user_id)))

    ~H"""
    <section
      id="triage-thread"
      data-qa="triage-thread"
      class="w-[470px] shrink-0 flex flex-col border-r border-slate-200 dark:border-slate-700 min-h-0"
    >
      <div class="px-5 py-4 border-b border-slate-200 dark:border-slate-700">
        <div class="flex items-center gap-2 text-xs text-slate-500 dark:text-slate-400">
          <.project_badge project={@thread.project} />
          <span class="font-mono">#{@thread.slack_channel.name}</span>
          <span>· {length(@thread.messages)} {if length(@thread.messages) == 1,
            do: "message",
            else: "messages"}</span>
          <a
            :if={@thread.permalink}
            href={@thread.permalink}
            target="_blank"
            rel="noopener noreferrer"
            id="open-in-slack"
            class="ml-auto inline-flex items-center gap-1 font-semibold text-blue-600 dark:text-blue-400"
          >
            <.icon name="pi-slack-logo" class="size-3.5" />Open in Slack
          </a>
        </div>
        <h2
          id="triage-thread-title"
          class="mt-2 text-lg font-bold leading-snug text-slate-900 dark:text-slate-100"
        >
          {Thread.title_or_preview(@thread)}
        </h2>
      </div>

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
              <span class="text-xs text-slate-500 dark:text-slate-400">{time(entry.message.posted_at)}</span>
            </p>
            <p class="text-[13px] leading-relaxed text-slate-800 dark:text-slate-200 whitespace-pre-line break-words">
              <span :for={{text, mark} <- entry.segments}><mark
                :if={mark}
                class={["text-inherit rounded px-0.5", mark]}
              >{text}</mark><span :if={!mark}>{text}</span></span>
            </p>
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

        <div
          :if={@corrections != []}
          id="triage-corrections"
          class="mx-2 mt-3 pt-3 border-t border-slate-200 dark:border-slate-700"
        >
          <p class="text-[11px] font-extrabold uppercase tracking-wider text-slate-500 dark:text-slate-400">
            Corrections
          </p>
          <div :for={entry <- @corrections} id={"triage-correction-#{entry.correction.id}"}>
            <div class="mt-2 w-fit max-w-[92%] ml-auto px-3 py-2 rounded-xl rounded-br-xs bg-slate-100 dark:bg-slate-800 border border-slate-200 dark:border-slate-700">
              <p class="flex items-center gap-1 text-[11px] font-semibold text-slate-500 dark:text-slate-400">
                <.icon name="pi-user" class="size-3" />{entry.who} · on item {entry.correction.item.position} · {time(
                  entry.correction.inserted_at
                )}
              </p>
              <p
                :if={entry.correction.assumption}
                class="text-[12px] text-slate-500 dark:text-slate-400"
              >
                Assumed: {entry.correction.assumption}
              </p>
              <p class="text-[13px] leading-relaxed text-slate-900 dark:text-slate-100">
                {entry.correction.text}
              </p>
            </div>
            <p
              :if={entry.redone_at}
              class="mt-1.5 text-right text-[11px] text-slate-500 dark:text-slate-400"
            >
              Item {entry.correction.item.position} triaged again at {time(entry.redone_at)}
            </p>
          </div>
        </div>
      </div>

      <.form
        :if={@picked}
        for={@correction}
        id="correction-form"
        phx-change="change_correction"
        phx-submit="send_correction"
        class="border-t border-slate-200 dark:border-slate-700 bg-slate-50 dark:bg-slate-800/30 px-4 py-3 space-y-2"
      >
        <div class="flex items-center gap-1.5 text-xs">
          <label for="correction-text" class="font-semibold text-slate-900 dark:text-slate-100 mr-1">Correct</label>
          <button
            :for={item <- @correctable}
            type="button"
            id={"correction-pick-#{item.id}"}
            phx-click={
              JS.push("pick_correction", value: %{item_id: item.id})
              |> JS.focus(to: "#correction-text")
            }
            aria-pressed={to_string(item.id == @picked.id)}
            class={[
              "whitespace-nowrap px-1.5 py-0.5 rounded text-[11px] font-bold",
              TriageVerdict.kind_style(item.kind).class,
              item.id == @picked.id && "ring-2 ring-blue-500",
              item.id != @picked.id && "opacity-70"
            ]}
          >
            {item.position} {Item.kind_label(item.kind)}
          </button>
          <span class="ml-auto whitespace-nowrap inline-flex items-center gap-1 text-[11px] text-slate-500 dark:text-slate-400">
            <.icon name="pi-lock-simple" class="size-3" />Never posted to Slack
          </span>
        </div>
        <input type="hidden" name="correction[item_id]" value={@picked.id} />
        <input type="hidden" name="correction[assumption]" value={@assumption} />
        <div
          :if={@assumption}
          id="correction-assumption"
          class="rounded-lg border-l-2 border-slate-500 bg-white dark:bg-slate-900 px-2.5 py-1.5 text-[12px] text-slate-500 dark:text-slate-400"
        >
          Assumed: {@assumption}
        </div>
        <div class="flex items-end gap-2">
          <textarea
            id="correction-text"
            name="correction[text]"
            rows="2"
            placeholder={"What did Rail get wrong about item #{@picked.position}? It triages that item again."}
            class="flex-1 resize-none px-2.5 py-1.5 text-[12.5px] rounded-lg border border-slate-500 dark:border-slate-400 bg-white dark:bg-slate-900 text-slate-900 dark:text-slate-100 placeholder-slate-500 dark:placeholder-slate-400"
          >{Ecto.Changeset.get_field(@correction, :text)}</textarea>
          <.button type="submit" id="send-correction-button">Send correction</.button>
        </div>
      </.form>
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

  defp correction(correction, current_user_id) do
    who =
      if correction.user_id == current_user_id, do: "You", else: (correction.user && correction.user.name) || "Someone"

    redone_at = correction.item.retriaged_at

    %{
      correction: correction,
      who: who,
      redone_at: if(redone_at && DateTime.after?(redone_at, correction.inserted_at), do: redone_at)
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

  defp time(%DateTime{} = at), do: Calendar.strftime(at, "%-I:%M %p")
end
