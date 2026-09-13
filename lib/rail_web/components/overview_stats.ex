defmodule RailWeb.Components.OverviewStats do
  @moduledoc """
  The three numbers across the top of the overview: what is in flight, what
  shipped this month against the month before, and what is waiting on a human.
  """
  use RailWeb, :html

  attr :stats, :map, required: true

  def overview_stats(assigns) do
    ~H"""
    <div
      id="overview-stats"
      data-qa="overview-stats"
      class="grid grid-cols-1 sm:grid-cols-3 rounded-xl border border-slate-200 dark:border-slate-700/70 bg-white dark:bg-slate-800/40 divide-y sm:divide-y-0 sm:divide-x divide-slate-200 dark:divide-slate-700/70"
    >
      <div id="stat-in-progress" class="px-5 py-4">
        <p class="text-[11px] font-medium uppercase tracking-[0.14em] text-slate-500 dark:text-slate-400">
          In progress
        </p>
        <p
          data-qa="stat-value"
          class="mt-1 text-3xl font-semibold tabular-nums text-slate-900 dark:text-slate-100"
        >
          {@stats.in_progress}
        </p>
      </div>

      <div id="stat-shipped" class="px-5 py-4">
        <p class="text-[11px] font-medium uppercase tracking-[0.14em] text-slate-500 dark:text-slate-400">
          Shipped · 30d
        </p>
        <p class="mt-1 flex items-baseline gap-2">
          <span
            data-qa="stat-value"
            class="text-3xl font-semibold tabular-nums text-slate-900 dark:text-slate-100"
          >
            {@stats.shipped}
          </span>
          <span
            id="stat-shipped-delta"
            class={[
              "text-sm",
              @stats.shipped_delta > 0 && "text-emerald-600 dark:text-emerald-400",
              @stats.shipped_delta < 0 && "text-red-600 dark:text-red-400",
              @stats.shipped_delta == 0 && "text-slate-500 dark:text-slate-400"
            ]}
          >
            <span :if={@stats.shipped_delta > 0}>+{@stats.shipped_delta} vs prior 30</span>
            <span :if={@stats.shipped_delta < 0}>{@stats.shipped_delta} vs prior 30</span>
            <span :if={@stats.shipped_delta == 0}>same as prior 30</span>
          </span>
        </p>
      </div>

      <div id="stat-waiting" class="px-5 py-4">
        <p class="text-[11px] font-medium uppercase tracking-[0.14em] text-slate-500 dark:text-slate-400">
          Waiting on you
        </p>
        <p class="mt-1 flex items-baseline gap-2">
          <span
            data-qa="stat-value"
            class={[
              "text-3xl font-semibold tabular-nums",
              @stats.waiting > 0 && "text-amber-600 dark:text-amber-400",
              @stats.waiting == 0 && "text-slate-900 dark:text-slate-100"
            ]}
          >
            {@stats.waiting}
          </span>
          <span
            :if={@stats.oldest_waiting}
            id="stat-oldest-waiting"
            class="text-sm text-slate-500 dark:text-slate-400"
          >
            oldest {@stats.oldest_waiting}
          </span>
        </p>
      </div>
    </div>
    """
  end
end
