defmodule RailWeb.Components.InProgressTasks do
  @moduledoc """
  Every task in progress and where it stands, grouped by project. Each links to its task.
  """
  use RailWeb, :html

  attr :groups, :list, required: true
  attr :count, :integer, required: true
  attr :is_filtered, :boolean, default: false

  def in_progress_tasks(assigns) do
    ~H"""
    <section id="in-progress-tasks" data-qa="in-progress-tasks">
      <div class="flex items-baseline justify-between mb-3">
        <h2 class="text-xs font-medium uppercase tracking-[0.14em] text-slate-500 dark:text-slate-400">
          In progress
        </h2>
        <span id="in-progress-count" class="font-mono text-xs text-slate-500 dark:text-slate-400">
          <span :if={@count == 1}>1 task</span>
          <span :if={@count != 1}>{@count} tasks</span>
        </span>
      </div>

      <p
        :if={@groups == []}
        id="in-progress-empty"
        class="rounded-xl border border-dashed border-slate-300 dark:border-slate-700 px-5 py-6 text-sm text-center text-slate-500 dark:text-slate-400"
      >
        Nothing is in progress.
      </p>

      <div class="space-y-5">
        <div
          :for={{project, entries} <- @groups}
          id={"in-progress-group-#{project.id}"}
          class="space-y-2"
        >
          <p
            :if={!@is_filtered}
            data-qa="in-progress-project-header"
            class="text-xs font-semibold text-slate-500 dark:text-slate-400 truncate"
          >
            {project.name}
          </p>

          <.link
            :for={entry <- entries}
            navigate={~p"/tasks/#{entry.task.id}"}
            id={"in-progress-task-#{entry.task.id}"}
            data-qa="in-progress-task"
            data-state={entry.state}
            class={[
              "flex gap-3 rounded-xl border px-4 py-3 transition-colors outline-none focus-visible:ring-2 focus-visible:ring-blue-500 focus-visible:ring-offset-2 focus-visible:ring-offset-white dark:focus-visible:ring-offset-slate-900",
              entry.is_waiting &&
                "border-amber-300 dark:border-amber-800/70 bg-amber-50 dark:bg-amber-950/30 hover:bg-amber-100/70 dark:hover:bg-amber-950/50",
              !entry.is_waiting &&
                "border-slate-200 dark:border-slate-700/70 bg-white dark:bg-slate-800/40 hover:bg-slate-50 dark:hover:bg-slate-800/70"
            ]}
          >
            <.icon name={entry.style.icon} class={["mt-[2px] size-4", entry.style.text_class]} />
            <span class="min-w-0 flex-1">
              <span
                class={[
                  "block truncate text-sm",
                  entry.is_waiting && "font-semibold text-slate-900 dark:text-slate-100",
                  !entry.is_waiting && "text-slate-800 dark:text-slate-200"
                ]}
                title={entry.task.issue.title}
              >
                {entry.task.issue.title}
              </span>
              <span class="mt-0.5 flex items-baseline justify-between gap-2 text-xs">
                <span class="min-w-0 truncate">
                  <span class={["font-semibold", entry.style.text_class]}>{entry.label}</span><span class="text-slate-500 dark:text-slate-400"> · <span class="font-mono">{entry.task.issue.identifier}</span></span>
                </span>
                <span
                  data-qa="in-progress-age"
                  class="shrink-0 font-mono text-slate-500 dark:text-slate-400"
                >
                  {entry.age}
                </span>
              </span>
            </span>
          </.link>
        </div>
      </div>
    </section>
    """
  end
end
