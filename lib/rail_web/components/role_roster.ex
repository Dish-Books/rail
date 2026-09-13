defmodule RailWeb.Components.RoleRoster do
  @moduledoc """
  Every agent role and what it is doing: waiting on a human, running, or what it
  last did. A role with a run to show links to that run's task.
  """
  use RailWeb, :html

  attr :groups, :list, required: true
  attr :is_filtered, :boolean, default: false
  attr :running_count, :integer, required: true
  attr :role_count, :integer, required: true

  def role_roster(assigns) do
    ~H"""
    <section id="role-roster" data-qa="overview-roster role-roster">
      <div class="flex items-baseline justify-between mb-3">
        <h2 class="text-xs font-medium uppercase tracking-[0.14em] text-slate-500 dark:text-slate-400">
          Agents
        </h2>
        <span id="roster-running-count" class="font-mono text-xs text-slate-500 dark:text-slate-400">
          {@running_count} / {@role_count} running
        </span>
      </div>

      <div class="space-y-5" id="roster-groups">
        <div :for={{project, entries} <- @groups} id={"roster-group-#{project.id}"} class="space-y-2">
          <p
            :if={!@is_filtered}
            id={"roster-project-header-#{project.id}"}
            data-qa="roster-project-header"
            class="text-xs font-semibold text-slate-500 dark:text-slate-400 truncate"
          >
            {project.name}
          </p>

          <p :if={entries == []} class="text-xs italic text-slate-500 dark:text-slate-400">
            No roles configured
          </p>

          <.link
            :for={entry <- entries}
            navigate={entry.run && ~p"/tasks/#{entry.run.task_id}"}
            id={"role-row-#{entry.role.id}"}
            data-qa="role-row"
            data-tone={entry.tone}
            class={[
              "flex gap-3 rounded-xl border px-4 py-3 transition-colors",
              entry.tone == :waiting &&
                "border-amber-300 dark:border-amber-800/70 bg-amber-50 dark:bg-amber-950/30 hover:bg-amber-100/70 dark:hover:bg-amber-950/50",
              entry.tone != :waiting &&
                "border-slate-200 dark:border-slate-700/70 bg-white dark:bg-slate-800/40",
              entry.tone != :waiting && entry.run && "hover:bg-slate-50 dark:hover:bg-slate-800/70",
              is_nil(entry.run) && "pointer-events-none"
            ]}
          >
            <span class={[
              "mt-1.5 h-2 w-2 shrink-0 rounded-full",
              entry.tone == :waiting && "bg-amber-500",
              entry.tone == :running && "bg-blue-500 animate-pulse",
              entry.tone == :failed && "bg-red-500",
              entry.tone == :idle && "bg-slate-400 dark:bg-slate-600"
            ]} />
            <span class="min-w-0">
              <span class={[
                "block truncate text-sm",
                entry.tone == :waiting && "font-semibold text-slate-900 dark:text-slate-100",
                entry.tone != :waiting && "text-slate-800 dark:text-slate-200"
              ]}>
                {entry.role.name}
              </span>
              <span
                data-qa="role-subtitle"
                class="block truncate text-xs text-slate-500 dark:text-slate-400"
              >
                {entry.subtitle}
              </span>
            </span>
          </.link>
        </div>
      </div>
    </section>
    """
  end
end
