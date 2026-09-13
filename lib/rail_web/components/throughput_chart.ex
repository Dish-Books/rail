defmodule RailWeb.Components.ThroughputChart do
  @moduledoc """
  Issues shipped per day, one bar a day, today's picked out.

  One series, so no legend: the caption names it. Each bar says its own date and
  count on hover, and the same numbers are listed for a screen reader.
  """
  use RailWeb, :html

  attr :days, :list, required: true, doc: "`%{date: Date.t(), count: integer}`, oldest first, today last"

  def throughput_chart(assigns) do
    assigns =
      assigns
      |> assign(:peak, assigns.days |> Enum.map(& &1.count) |> Enum.max(fn -> 0 end) |> max(1))
      |> assign(:total, Enum.sum_by(assigns.days, & &1.count))
      |> assign(:today, List.last(assigns.days))

    ~H"""
    <div
      id="throughput-chart"
      data-qa="throughput-chart"
      class="rounded-xl border border-slate-200 dark:border-slate-700/70 bg-white dark:bg-slate-800/40 px-5 pt-5 pb-4"
    >
      <div class="flex h-24 items-end gap-[2px]" aria-hidden="true">
        <div :for={day <- @days} class="group relative flex h-full flex-1 items-end">
          <div
            data-qa="throughput-bar"
            data-count={day.count}
            style={"height: max(2px, #{day.count / @peak * 100}%)"}
            class={[
              "w-full rounded-t-[4px]",
              day == @today && "bg-blue-600 dark:bg-blue-500",
              day != @today && day.count > 0 && "bg-slate-300 dark:bg-slate-600",
              day != @today && day.count == 0 && "bg-slate-200 dark:bg-slate-700/60"
            ]}
          />
          <span class="pointer-events-none absolute bottom-full left-1/2 z-10 mb-1.5 hidden -translate-x-1/2 whitespace-nowrap rounded-md bg-slate-900 dark:bg-slate-100 px-2 py-1 text-[11px] text-slate-100 dark:text-slate-900 shadow-lg group-hover:block">
            {Calendar.strftime(day.date, "%b %-d")} · {day.count} shipped
          </span>
        </div>
      </div>

      <ul class="sr-only">
        <li :for={day <- @days}>{Calendar.strftime(day.date, "%b %-d")}: {day.count} shipped</li>
      </ul>

      <div class="mt-3 flex items-baseline justify-between gap-3 whitespace-nowrap text-xs text-slate-500 dark:text-slate-400">
        <span class="min-w-0 truncate">Shipped per day · {length(@days)}d</span>
        <span id="throughput-total" class="shrink-0 font-mono">{@total} total</span>
      </div>
    </div>
    """
  end
end
