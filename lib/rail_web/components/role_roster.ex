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
      data-qa="role-roster"
      class="w-[268px] shrink-0 border-l border-[var(--color-border)] pl-6 py-1 select-none hidden lg:block"
    >
      <h2
        id="roster-header"
        data-qa="roster-header"
        class="text-xs font-bold uppercase tracking-wider text-[var(--color-outline)] mb-3"
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
            class="flex items-center space-x-1.5 text-xs font-semibold text-[var(--color-outline)] pb-1 border-b border-[var(--color-border)]"
          >
            <.icon name="folder" class="h-3.5 w-3.5 text-[var(--color-primary)]" />
            <span class="truncate">{project.name}</span>
            <span :if={project.linear_team_key} class="font-mono text-[10px] opacity-75">
              ({project.linear_team_key})
            </span>
          </div>

          <!-- Empty roles notice if project has no roles -->
          <p
            :if={role_entries == []}
            class="text-xs text-[var(--color-outline)] italic py-1"
          >
            No roles configured
          </p>

          <!-- Role Rows -->
          <div :for={entry <- role_entries} id={"role-row-#{entry.role.id}"} data-qa="role-row">
            <.link
              :if={entry.active_task}
              navigate={~p"/tasks/#{entry.active_task.id}"}
              id={"role-active-link-#{entry.role.id}"}
              data-qa="role-active-link"
              class="flex items-center space-x-2.5 p-2 rounded-lg border border-[var(--color-border)] bg-[var(--color-surface)] hover:bg-[var(--color-surface-container-high)] transition-colors shadow-xs group"
            >
              <.role_avatar role={entry.role} />
              <div class="min-w-0 flex-1">
                <p class="text-xs font-semibold text-[var(--color-on-surface)] truncate">
                  {entry.role.name}
                </p>
                <p
                  data-qa="role-subtitle"
                  class={[
                    "text-[11px] truncate",
                    entry.waiting? && "text-amber-600 dark:text-amber-400 font-medium",
                    !entry.waiting? && "text-[var(--color-outline)]"
                  ]}
                >
                  {entry.subtitle}
                </p>
              </div>
            </.link>

            <div
              :if={is_nil(entry.active_task)}
              id={"role-idle-#{entry.role.id}"}
              data-qa="role-idle"
              class="flex items-center space-x-2.5 p-2 rounded-lg border border-[var(--color-border)] bg-[var(--color-surface)] shadow-xs opacity-75"
            >
              <.role_avatar role={entry.role} />
              <div class="min-w-0 flex-1">
                <p class="text-xs font-semibold text-[var(--color-on-surface)] truncate">
                  {entry.role.name}
                </p>
                <p data-qa="role-subtitle" class="text-[11px] text-[var(--color-outline)] truncate">
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
    icon_name = icon_for_role(assigns.role)
    assigns = assign(assigns, :icon_name, icon_name)

    ~H"""
    <div class="flex items-center justify-center h-7 w-7 rounded-full bg-[var(--color-surface-container-highest)] text-[var(--color-on-surface-variant)] shrink-0">
      <.icon name={@icon_name} class="h-4 w-4" />
    </div>
    """
  end

  defp icon_for_role(%{icon_name: icon_name}) when is_binary(icon_name) and icon_name != "" do
    icon_name
  end

  defp icon_for_role(%{stage: :engineer}), do: "code"
  defp icon_for_role(%{stage: :architect}), do: "architecture"
  defp icon_for_role(%{stage: :design}), do: "palette"
  defp icon_for_role(%{stage: :demo}), do: "videocam"
  defp icon_for_role(%{stage: s}) when s in [:qa, :qa_lead], do: "fact_check"
  defp icon_for_role(_role), do: "smart_toy"
end
