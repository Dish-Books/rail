defmodule RailWeb.Components.PlanQueue do
  @moduledoc """
  Overview's plans to approve: every task whose owner sent its plan to the tech leads and no tech lead has approved,
  oldest send first, with the ones its owner already started marked. A row opens the task on its plan, where the
  header's Approve plan is.
  """
  use RailWeb, :html

  alias Rail.Pipeline.Schemas.Round
  alias Rail.Pipeline.Schemas.Task

  # Tasks from `Rail.Pipeline.list_tasks(plan_ready: true)`, each with its project, issue and rounds.
  attr :tasks, :list, required: true
  attr :now, DateTime, required: true

  def plan_queue(assigns) do
    ~H"""
    <section :if={@tasks != []} id="plan-queue-section">
      <div class="mb-3 flex items-baseline justify-between">
        <h2 class="text-xs font-medium uppercase tracking-[0.14em] text-slate-500 dark:text-slate-400">
          Plans to approve
        </h2>
        <span id="plan-queue-count" class="font-mono text-xs text-slate-500 dark:text-slate-400">
          {if length(@tasks) == 1, do: "1 plan", else: "#{length(@tasks)} plans"}
        </span>
      </div>

      <div id="plan-queue" class="space-y-3">
        <.link
          :for={task <- @tasks}
          navigate={~p"/tasks/#{task.id}?item=plan"}
          id={"plan-queue-row-#{task.issue.identifier}"}
          class="group flex items-center gap-4 rounded-xl border border-slate-200 dark:border-slate-700/70 bg-white dark:bg-slate-800/40 px-5 py-3.5 transition-colors hover:bg-slate-50 dark:hover:bg-slate-800/70 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500"
        >
          <.project_badge project={task.project} />
          <span class="font-mono text-xs text-slate-500 dark:text-slate-400 shrink-0 whitespace-nowrap">
            {task.issue.identifier}
          </span>
          <span
            class="min-w-0 flex-1 truncate text-sm text-slate-900 dark:text-slate-100"
            title={task.issue.title}
          >
            {task.issue.title}
          </span>
          <span
            :if={task.stage != :plan}
            data-qa="plan_queue_started"
            class="shrink-0 inline-flex items-center gap-1 text-xs font-semibold text-amber-700 dark:text-amber-300"
          >
            <.icon name="pi-play" class="size-3.5" />Started without approval
          </span>
          <span class="shrink-0 w-9 text-right font-mono text-xs text-slate-500 dark:text-slate-400">
            {format_age(DateTime.diff(@now, sent_at(task)))}
          </span>
        </.link>
      </div>
    </section>
    """
  end

  defp sent_at(%Task{rounds: [%Round{ready_at: %DateTime{} = at} | _later]}), do: at
end
