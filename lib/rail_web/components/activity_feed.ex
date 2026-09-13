defmodule RailWeb.Components.ActivityFeed do
  @moduledoc """
  What happened since yesterday, newest first: each entry a moment, who did it,
  and what they did.
  """
  use RailWeb, :html

  attr :entries, :list, required: true

  def activity_feed(assigns) do
    ~H"""
    <div id="activity-feed" data-qa="activity-feed">
      <p
        :if={@entries == []}
        id="activity-feed-empty"
        class="text-sm text-slate-500 dark:text-slate-400"
      >
        Nothing has happened since yesterday.
      </p>

      <ol :if={@entries != []} class="space-y-3">
        <li
          :for={entry <- @entries}
          id={"activity-#{entry.id}"}
          data-qa="activity-entry"
          class="flex gap-5 text-[15px]"
        >
          <time
            id={"activity-time-#{entry.id}"}
            phx-hook="LocalTime"
            datetime={DateTime.to_iso8601(entry.at)}
            data-at={DateTime.to_iso8601(entry.at)}
            class="w-20 shrink-0 whitespace-nowrap pt-0.5 font-mono text-sm tabular-nums text-slate-500 dark:text-slate-400"
          >
            {Calendar.strftime(entry.at, "%H:%M")}
          </time>
          <p class={[
            "min-w-0",
            entry.actor && "text-slate-700 dark:text-slate-300",
            !entry.actor && "text-slate-500 dark:text-slate-400"
          ]}>
            <strong :if={entry.actor} class="font-semibold text-slate-900 dark:text-slate-100">{entry.actor}</strong>
            {entry.text}
          </p>
        </li>
      </ol>
    </div>
    """
  end
end
