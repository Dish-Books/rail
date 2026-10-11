defmodule RailWeb.Components.SandboxStats do
  @moduledoc """
  The four numbers across the top of the Sandboxes page: how many of the machine's
  CPUs are reserved, how much of its memory is in use, what is running, and what
  is waiting for resources.
  """
  use RailWeb, :html

  attr :stats, :map, required: true

  def sandbox_stats(assigns) do
    ~H"""
    <div
      id="sandbox-stats"
      data-qa="sandbox-stats"
      class="grid grid-cols-1 sm:grid-cols-2 xl:grid-cols-4 rounded-xl border border-slate-200 dark:border-slate-700/70 bg-white dark:bg-slate-800/40 divide-y xl:divide-y-0 xl:divide-x divide-slate-200 dark:divide-slate-700/70"
    >
      <div id="stat-cpus-reserved" class="px-5 py-4">
        <p class="text-[11px] font-medium uppercase tracking-[0.14em] text-slate-500 dark:text-slate-400">
          CPUs reserved
        </p>
        <p class="mt-1 flex items-baseline gap-2">
          <span class="text-3xl font-semibold tabular-nums text-slate-900 dark:text-slate-100">
            {@stats.reserved_cpus}
          </span>
          <span class="text-sm text-slate-500 dark:text-slate-400">
            of {@stats.cpus} · {free(@stats.cpus - @stats.reserved_cpus)}
          </span>
        </p>
        <div class="mt-3 flex h-2 rounded-full overflow-hidden bg-slate-200 dark:bg-slate-700/70">
          <span
            class="h-full bg-blue-500"
            style={"width:#{percent(@stats.reserved_cpus, @stats.cpus)}%"}
          />
        </div>
      </div>

      <div id="stat-memory-used" class="px-5 py-4">
        <p class="text-[11px] font-medium uppercase tracking-[0.14em] text-slate-500 dark:text-slate-400">
          Memory in use
        </p>
        <p class="mt-1 flex items-baseline gap-2">
          <span class="text-3xl font-semibold tabular-nums text-slate-900 dark:text-slate-100">
            {memory(@stats.used_memory_gb)}
          </span>
          <span class="text-sm text-slate-500 dark:text-slate-400">
            of {@stats.memory_gb} GB on this machine
          </span>
        </p>
        <div class="mt-3 flex h-2 rounded-full overflow-hidden bg-slate-200 dark:bg-slate-700/70">
          <span
            class="h-full bg-blue-500"
            style={"width:#{percent(@stats.used_memory_gb || 0, @stats.memory_gb)}%"}
          />
        </div>
      </div>

      <div id="stat-running" class="px-5 py-4">
        <p class="text-[11px] font-medium uppercase tracking-[0.14em] text-slate-500 dark:text-slate-400">
          Running
        </p>
        <p class="mt-1 text-3xl font-semibold tabular-nums text-slate-900 dark:text-slate-100">
          {@stats.running}
        </p>
        <p class="mt-2 text-xs text-slate-500 dark:text-slate-400">
          {@stats.agent_turns} {if @stats.agent_turns == 1, do: "agent turn", else: "agent turns"} · {@stats.setups} setup · {@stats.cis} CI
        </p>
      </div>

      <div id="stat-waiting" class="px-5 py-4">
        <p class="text-[11px] font-medium uppercase tracking-[0.14em] text-slate-500 dark:text-slate-400">
          Waiting for resources
        </p>
        <p class="mt-1 flex items-baseline gap-2">
          <span
            data-qa="stat-value"
            class={[
              "text-3xl font-semibold tabular-nums",
              @stats.waiting > 0 && "text-violet-600 dark:text-violet-400",
              @stats.waiting == 0 && "text-slate-900 dark:text-slate-100"
            ]}
          >
            {@stats.waiting}
          </span>
          <span :if={@stats.oldest_waiting} class="text-sm text-slate-500 dark:text-slate-400">
            oldest {@stats.oldest_waiting}
          </span>
        </p>
        <p class="mt-2 text-xs text-slate-500 dark:text-slate-400">
          {short_on(@stats.waiting, @stats.short_on_cpus?)}
        </p>
      </div>
    </div>
    """
  end

  defp free(amount) when amount <= 0, do: "none free"
  defp free(amount), do: "#{amount} free"

  # Nothing is in use on a machine that cannot say; it is a dash, not a zero.
  defp memory(nil), do: "—"
  defp memory(used), do: "#{:erlang.float_to_binary(used / 1, decimals: 1)} GB"

  defp percent(reserved, total), do: min(Float.round(reserved / max(total, 1) * 100, 1), 100)

  defp short_on(0, _short_on_cpus?), do: "Nothing is waiting."
  defp short_on(_waiting, true), do: "Short on CPUs."
  defp short_on(_waiting, false), do: "Each waits for the ones ahead of it."
end
