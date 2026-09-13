defmodule RailWeb.Components.RoleRoster do
  @moduledoc false
  use RailWeb, :html

  import RailWeb.CoreComponents, only: [icon: 1]

  attr :groups, :list, required: true
  attr :is_filtered, :boolean, default: false

  def role_roster(assigns) do
    ~H"""
    <aside
      id="role-roster"
      data-qa="overview-roster role-roster"
      class="w-[268px] shrink-0 border-l border-slate-200 dark:border-slate-700 pl-6 py-1 select-none hidden lg:block"
    >
      <h2
        id="roster-header"
        data-qa="roster-header"
        class="text-xs font-bold uppercase tracking-wider text-slate-500 dark:text-slate-400 mb-3"
      >
        AGENT ROLES
      </h2>

      <div class="space-y-4" id="roster-groups">
        <div
          :for={{project, role_entries} <- @groups}
          id={"roster-group-#{project.id}"}
          class="space-y-2"
        >
          <!-- Project Group Header (shown when unfiltered across projects) -->
          <div
            :if={!@is_filtered}
            id={"roster-project-header-#{project.id}"}
            data-qa="roster-project-header"
            class="flex items-center space-x-1.5 text-xs font-semibold text-slate-500 dark:text-slate-400 pb-1 border-b border-slate-200 dark:border-slate-700"
          >
            <.icon name="pi-folder-fill" class="h-3.5 w-3.5 text-blue-600 dark:text-blue-500" />
            <span class="truncate">{project.name}</span>
            <span :if={project.linear_team_key} class="font-mono text-[10px] opacity-75">
              ({project.linear_team_key})
            </span>
          </div>

          <!-- Empty roles notice if project has no roles -->
          <p
            :if={role_entries == []}
            class="text-xs text-slate-500 dark:text-slate-400 italic py-1"
          >
            No roles configured
          </p>

          <!-- Role Rows -->
          <div :for={entry <- role_entries} id={"role-row-#{entry.role.id}"} data-qa="role-row">
            <.link
              :if={entry.active_run}
              navigate={~p"/tasks/#{entry.active_run.task_id}"}
              id={"role-active-link-#{entry.role.id}"}
              data-qa="role-active-link"
              class="flex items-center space-x-2.5 p-2 rounded-lg border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-900 hover:bg-slate-100 dark:hover:bg-slate-700 transition-colors shadow-xs group"
            >
              <.role_avatar role={entry.role} />
              <div class="min-w-0 flex-1">
                <p class="text-xs font-semibold text-slate-900 dark:text-slate-100 truncate">
                  {entry.role.name}
                </p>
                <p
                  data-qa="role-subtitle"
                  class={[
                    "text-[11px] truncate",
                    entry.waiting? && "text-amber-600 dark:text-amber-400 font-medium",
                    !entry.waiting? && "text-slate-500 dark:text-slate-400"
                  ]}
                >
                  {entry.subtitle}
                </p>
              </div>
            </.link>

            <div
              :if={is_nil(entry.active_run)}
              id={"role-idle-#{entry.role.id}"}
              data-qa="role-idle"
              class="flex items-center space-x-2.5 p-2 rounded-lg border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-900 shadow-xs opacity-75"
            >
              <.role_avatar role={entry.role} />
              <div class="min-w-0 flex-1">
                <p class="text-xs font-semibold text-slate-900 dark:text-slate-100 truncate">
                  {entry.role.name}
                </p>
                <p
                  data-qa="role-subtitle"
                  class="text-[11px] text-slate-500 dark:text-slate-400 truncate"
                >
                  Idle
                </p>
              </div>
            </div>
          </div>
        </div>
      </div>
    </aside>
    """
  end

  attr :role, :any, required: true

  def role_avatar(assigns) do
    ~H"""
    <div class="flex items-center justify-center h-7 w-7 rounded-full bg-slate-200 dark:bg-slate-600 text-slate-600 dark:text-slate-300 shrink-0">
      <.icon name={@role.icon_name} class="h-4 w-4" />
    </div>
    """
  end
end
