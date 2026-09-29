defmodule RailWeb.Components.SandboxMeters do
  @moduledoc """
  The Overview's view of the machine: how much of its CPU and memory running
  sandboxes reserve, one segment each, and what waits for the rest.
  """
  use RailWeb, :html

  attr :capacity, :map, required: true
  attr :running, :list, required: true, doc: "running sandboxes, each with its reservation"
  attr :waiting, :integer, required: true
  attr :oldest_waiting, :string, default: nil

  def sandbox_meters(assigns) do
    ~H"""
    <section id="sandbox-meters" data-qa="sandbox-meters">
      <div class="flex items-baseline justify-between mb-3">
        <h2 class="text-xs font-medium uppercase tracking-[0.14em] text-slate-500 dark:text-slate-400">
          Sandboxes
        </h2>
        <span id="sandbox-meters-count" class="font-mono text-xs text-slate-500 dark:text-slate-400">
          {length(@running)} running · {@waiting} waiting
        </span>
      </div>

      <div class="rounded-xl border border-slate-200 dark:border-slate-700/70 bg-white dark:bg-slate-800/40 px-4 py-4 space-y-4">
        <div id="sandbox-meter-cpus">
          <div class="flex items-baseline justify-between text-xs mb-1.5">
            <span class="flex items-center gap-1.5 font-semibold text-slate-800 dark:text-slate-200">
              <.icon name="pi-cpu" class="size-4 text-slate-400" />CPUs
            </span>
            <span class="font-mono text-slate-500 dark:text-slate-400">
              <span class="text-slate-900 dark:text-slate-100">{@capacity.reserved_cpus} of {@capacity.cpus}</span>
              reserved
            </span>
          </div>
          <div class="flex h-2.5 gap-[2px] rounded-full overflow-hidden bg-slate-200 dark:bg-slate-700/70">
            <span
              :for={sandbox <- @running}
              class="h-full bg-blue-500"
              style={"width:#{share(sandbox.reserved_cpus, @capacity.cpus)}%"}
            />
          </div>
          <p class="mt-1 font-mono text-[11px] text-slate-500 dark:text-slate-400">
            {max(@capacity.cpus - @capacity.reserved_cpus, 0)} {if @capacity.cpus -
                                                                     @capacity.reserved_cpus == 1,
                                                                   do: "CPU",
                                                                   else: "CPUs"} free
          </p>
        </div>

        <div id="sandbox-meter-memory">
          <div class="flex items-baseline justify-between text-xs mb-1.5">
            <span class="flex items-center gap-1.5 font-semibold text-slate-800 dark:text-slate-200">
              <.icon name="pi-memory" class="size-4 text-slate-400" />Memory
            </span>
            <span class="font-mono text-slate-500 dark:text-slate-400">
              <span class="text-slate-900 dark:text-slate-100">{@capacity.reserved_memory_gb} of {@capacity.memory_gb} GB</span>
              reserved
            </span>
          </div>
          <div class="flex h-2.5 gap-[2px] rounded-full overflow-hidden bg-slate-200 dark:bg-slate-700/70">
            <span
              :for={sandbox <- @running}
              class="h-full bg-blue-500"
              style={"width:#{share(sandbox.reserved_memory_gb, @capacity.memory_gb)}%"}
            />
          </div>
          <p class="mt-1 font-mono text-[11px] text-slate-500 dark:text-slate-400">
            {max(@capacity.memory_gb - @capacity.reserved_memory_gb, 0)} GB free
          </p>
        </div>

        <.link
          navigate={~p"/sandboxes"}
          id="open-sandboxes"
          class="flex items-center justify-between text-xs font-semibold text-blue-600 dark:text-blue-400 hover:underline"
        >
          <span :if={@waiting > 0}>{@waiting} waiting · oldest {@oldest_waiting}</span>
          <span :if={@waiting == 0}>Nothing waiting</span>
          <span class="inline-flex items-center gap-1">
            Open Sandboxes<.icon name="pi-arrow-right" class="size-3.5" />
          </span>
        </.link>
      </div>
    </section>
    """
  end

  defp share(reserved, total), do: Float.round(reserved / max(total, 1) * 100, 2)
end
