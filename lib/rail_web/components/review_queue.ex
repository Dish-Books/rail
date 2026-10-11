defmodule RailWeb.Components.ReviewQueue do
  @moduledoc """
  Overview's review queue: every task a teammate marked ready at Finalize and nobody has merged, oldest mark
  first, whoever owns it. A row only opens the task's Finalize tab; merging happens there.
  """
  use RailWeb, :html

  alias Rail.Pipeline.Schemas.Task

  # Tasks from `Rail.Pipeline.list_tasks(ready: true)`, each with its project, issue and who marked it.
  attr :tasks, :list, required: true
  attr :now, DateTime, required: true

  def review_queue(assigns) do
    ~H"""
    <section id="review-queue-section">
      <div class="mb-3 flex items-baseline justify-between">
        <h2 class="text-xs font-medium uppercase tracking-[0.14em] text-slate-500 dark:text-slate-400">
          Review queue
        </h2>
        <span
          :if={@tasks != []}
          id="review-queue-count"
          class="font-mono text-xs text-slate-500 dark:text-slate-400"
        >
          {if length(@tasks) == 1, do: "1 task", else: "#{length(@tasks)} tasks"}
        </span>
      </div>

      <p
        :if={@tasks == []}
        id="review-queue-empty"
        class="rounded-xl border border-dashed border-slate-300 dark:border-slate-700 px-5 py-6 text-sm text-center text-slate-500 dark:text-slate-400"
      >
        Nothing is waiting for a tech lead.
      </p>

      <div :if={@tasks != []} id="review-queue" class="space-y-3">
        <.link
          :for={task <- @tasks}
          navigate={~p"/tasks/#{task.id}?tab=finalize"}
          id={"review-queue-row-#{task.issue.identifier}"}
          data-state={Task.finalize_state(task)}
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
            {task.issue.title} ·
            <span class="text-slate-500 dark:text-slate-400">marked by {marked_by(task)}</span>
          </span>
          <span
            :if={Task.finalize_state(task) == :refused}
            class="shrink-0 inline-flex items-center gap-1 text-xs font-semibold text-red-600 dark:text-red-400"
          >
            <.icon name="pi-warning-circle" class="size-3.5" />Merge refused
          </span>
          <span
            :if={Task.finalize_state(task) == :merging}
            class="shrink-0 inline-flex items-center gap-1 text-xs font-semibold text-blue-600 dark:text-blue-400"
          >
            <.icon name="pi-circle-notch" class="size-3.5 motion-safe:animate-spin" />Merging
          </span>
          <span class="shrink-0 inline-flex items-center gap-1 font-mono text-xs text-blue-600 dark:text-blue-400">
            <.icon name="pi-git-pull-request" class="size-3.5" />#{task.pr_number}
          </span>
          <span class="shrink-0 w-9 text-right font-mono text-xs text-slate-500 dark:text-slate-400">
            {format_age(DateTime.diff(@now, task.marked_ready_at))}
          </span>
        </.link>
      </div>
    </section>
    """
  end

  # A user deleted since leaves the mark with nobody's name on it.
  defp marked_by(%Task{marked_ready_by: %{name: name, login: login}}), do: if(name in [nil, ""], do: login, else: name)
  defp marked_by(%Task{}), do: "someone"
end
