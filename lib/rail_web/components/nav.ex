defmodule RailWeb.Components.Nav do
  @moduledoc """
  The navigation rail, icons only, and the bar across the top, kept narrow so the task page has the width.
  """
  use RailWeb, :html

  alias RailWeb.Components.CaptureIssueModal

  attr :current_section, :atom, required: true
  attr :attention_count, :integer, default: 0
  attr :triage_count, :integer, default: 0

  def nav(assigns) do
    ~H"""
    <aside
      id="navigation-rail"
      data-qa="navigation_rail"
      class="flex flex-col items-center h-full w-12 shrink-0 border-r border-slate-200 dark:border-slate-700 bg-slate-50 dark:bg-slate-800 select-none"
    >
      <!-- Top Group: Logo and Destinations -->
      <div class="flex flex-col items-center space-y-3 py-2">
        <!-- Brand / Leading -->
        <div class="flex items-center py-1" id="app-brand" title="Rail">
          <div class="flex items-center justify-center h-8 w-8 rounded-lg bg-blue-100 dark:bg-blue-900 text-blue-800 dark:text-blue-200 shrink-0">
            <svg viewBox="0 0 64 64" class="h-8 w-8" fill="none" aria-hidden="true" id="brand-mark">
              <mask id="brand-mark-rails" stroke-linejoin="round">
                <path
                  d="M21 56V17H35a9.5 9.5 0 0 1 0 19H21M32 36 46 57"
                  stroke="#fff"
                  stroke-width="12"
                />
                <path
                  d="M21 56V17H35a9.5 9.5 0 0 1 0 19H21M32 36 46 57"
                  stroke="#000"
                  stroke-width="4.5"
                />
              </mask>
              <rect width="64" height="52" fill="currentColor" mask="url(#brand-mark-rails)" />
            </svg>
          </div>
        </div>

        <!-- Destinations List -->
        <nav class="flex flex-col space-y-1" id="nav-destinations" aria-label="Main Navigation">
          <.nav_item
            section={:overview}
            active={@current_section == :overview}
            label="Overview"
            icon_active="pi-squares-four-fill"
            icon_inactive="pi-squares-four"
            href={~p"/"}
            attention_count={@attention_count}
          />

          <.nav_item
            section={:triage}
            active={@current_section == :triage}
            label="Triage"
            icon_active="pi-chat-circle-text-fill"
            icon_inactive="pi-chat-circle-text"
            href={~p"/triage"}
            attention_count={@triage_count}
            badge_id="triage-badge"
          />

          <.nav_item
            section={:issues}
            active={@current_section == :issues}
            label="Issues"
            icon_active="pi-lightbulb-fill"
            icon_inactive="pi-lightbulb"
            href={~p"/issues"}
            attention_count={0}
          />

          <.nav_item
            section={:learnings}
            active={@current_section == :learnings}
            label="Learnings"
            icon_active="pi-brain-fill"
            icon_inactive="pi-brain"
            href={~p"/learnings"}
            attention_count={0}
          />

          <.nav_item
            section={:sandboxes}
            active={@current_section == :sandboxes}
            label="Sandboxes"
            icon_active="pi-cube-fill"
            icon_inactive="pi-cube"
            href={~p"/sandboxes"}
            attention_count={0}
          />

          <.nav_item
            section={:settings}
            active={
              @current_section in [
                :settings,
                :connected_accounts,
                :projects,
                :linear_workspaces,
                :users,
                :roles,
                :backends,
                :mcp_servers,
                :slack_workspaces
              ]
            }
            label="Settings"
            icon_active="pi-gear-fill"
            icon_inactive="pi-gear"
            href={~p"/settings/connected-accounts"}
            attention_count={0}
          />
        </nav>
      </div>
    </aside>
    """
  end

  attr :section, :atom, required: true
  attr :active, :boolean, required: true
  attr :label, :string, required: true
  attr :icon_active, :string, required: true
  attr :icon_inactive, :string, required: true
  attr :href, :string, required: true
  attr :attention_count, :integer, default: 0
  attr :badge_id, :string, default: "attention-badge"

  def nav_item(assigns) do
    ~H"""
    <.link
      navigate={@href}
      id={"nav-#{destination_slug(@section)}"}
      data-qa={"nav_#{destination_slug(@section)}"}
      data-active={if @active, do: "true", else: "false"}
      title={@label}
      aria-label={@label}
      class={[
        "flex items-center justify-center h-9 w-9 rounded-lg transition-colors relative",
        @active &&
          "bg-blue-100 dark:bg-blue-900 text-blue-800 dark:text-blue-200 font-semibold shadow-xs",
        !@active &&
          "text-slate-500 dark:text-slate-400 hover:bg-slate-100 dark:hover:bg-slate-700 hover:text-slate-900 dark:hover:text-slate-100"
      ]}
    >
      <div class="relative flex items-center justify-center shrink-0">
        <.icon :if={@active} name={@icon_active} class="h-5 w-5" />
        <.icon :if={!@active} name={@icon_inactive} class="h-5 w-5" />
        <span
          :if={@attention_count > 0}
          id={@badge_id}
          data-qa={String.replace(@badge_id, "-", "_")}
          class="absolute -top-1.5 -right-1.5 flex h-4 min-w-4 items-center justify-center rounded-full bg-amber-600 px-1 text-[10px] font-bold text-white ring-2 ring-slate-50 dark:ring-slate-800"
        >
          {@attention_count}
        </span>
      </div>
    </.link>
    """
  end

  attr :current_section, :atom, required: true
  attr :current_scope, Rail.Scope, required: true
  attr :current_project_id, :string, default: nil
  attr :projects, :list, default: []
  attr :theme, :string, default: "dark"
  attr :show_project_switcher, :boolean, default: false

  def top_app_bar(assigns) do
    active_projects = Enum.filter(assigns.projects, & &1.active)
    selected_project = Enum.find(assigns.projects, &(&1.id == assigns.current_project_id))
    assigns = assign(assigns, :active_projects, active_projects)
    assigns = assign(assigns, :selected_project, selected_project)

    ~H"""
    <header
      id="top-app-bar"
      data-qa="top_app_bar"
      class="h-11 px-4 flex items-center justify-between border-b border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-900 shrink-0 z-20"
    >
      <!-- Left Group: Section Title & Project Filter -->
      <div class="flex items-center space-x-4">
        <h1
          id="section-title"
          data-qa="section_title"
          class="text-sm font-semibold tracking-tight text-slate-900 dark:text-slate-100 whitespace-nowrap"
        >
          {section_title(@current_section)}
        </h1>

        <!-- Project Switcher Pill Button -->
        <!-- On the wrapper, so clicking the button toggles it shut rather than closing and reopening it. -->
        <div
          id="project-switcher"
          class="relative"
          phx-click-away={@show_project_switcher && "close_project_switcher"}
        >
          <button
            type="button"
            id="project-switcher-button"
            data-qa="project_switcher_button"
            phx-click="toggle_project_switcher"
            class="flex items-center space-x-1.5 px-2.5 py-1 rounded-lg border border-slate-300 dark:border-slate-600 bg-slate-100 dark:bg-slate-700 hover:bg-slate-200 dark:hover:bg-slate-600 text-xs font-medium text-slate-900 dark:text-slate-100 transition-colors shadow-xs"
          >
            <.icon name="pi-folder" class="h-4 w-4 text-blue-600 dark:text-blue-500" />
            <span
              :if={is_nil(@selected_project)}
              id="selected-project-name"
              class="max-w-[160px] truncate"
            >
              All projects
            </span>
            <span
              :if={is_nil(@selected_project)}
              id="active-project-count"
              data-qa="active_project_count"
              class="ml-1 px-1.5 py-0.2 rounded-full text-[10px] font-semibold bg-slate-200 dark:bg-slate-600 text-slate-900 dark:text-slate-100 ring-1 ring-inset ring-slate-300 dark:ring-slate-600"
            >
              {length(@active_projects)}
            </span>
            <span
              :if={not is_nil(@selected_project)}
              id="selected-project-name"
              class="max-w-[160px] truncate font-semibold"
            >
              {@selected_project.name}
            </span>
            <.icon name="pi-caret-up-down" class="h-3.5 w-3.5 text-slate-500 dark:text-slate-400" />
          </button>

          <!-- Project Switcher Dropdown Dialog -->
          <div
            :if={@show_project_switcher}
            id="project-switcher-dialog"
            data-qa="project_switcher_dialog"
            phx-window-keydown="close_project_switcher"
            phx-key="Escape"
            class="absolute left-0 mt-2 w-64 rounded-xl border border-slate-200 dark:border-slate-700 bg-slate-50 dark:bg-slate-800 p-1.5 shadow-xl z-50 focus:outline-none"
          >
            <div class="px-2 py-1.5 text-[11px] font-semibold uppercase tracking-wider text-slate-500 dark:text-slate-400">
              Projects
            </div>

            <!-- All Projects Option -->
            <button
              type="button"
              id="project-option-all"
              data-qa="project_option_all"
              phx-click="select_project"
              phx-value-project_id=""
              class={[
                "flex items-center justify-between w-full px-2.5 py-2 rounded-lg text-xs transition-colors",
                is_nil(@selected_project) &&
                  "bg-blue-100 dark:bg-blue-900 text-blue-800 dark:text-blue-200 font-semibold",
                not is_nil(@selected_project) &&
                  "text-slate-900 dark:text-slate-100 hover:bg-slate-100 dark:hover:bg-slate-700"
              ]}
            >
              <div class="flex items-center space-x-2">
                <.icon name="pi-folder" class="h-4 w-4 text-blue-600 dark:text-blue-500" />
                <span>All projects</span>
              </div>
              <span class="text-[10px] opacity-75 font-mono">
                {length(@active_projects)} active
              </span>
            </button>

            <!-- Project Options -->
            <div class="mt-1 max-h-56 overflow-y-auto space-y-0.5" id="project-options-list">
              <button
                :for={project <- @active_projects}
                type="button"
                id={"project-option-#{project.id}"}
                data-qa={"project_option_#{project.id}"}
                phx-click="select_project"
                phx-value-project_id={project.id}
                class={[
                  "flex items-center justify-between w-full px-2.5 py-2 rounded-lg text-xs transition-colors",
                  @current_project_id == project.id &&
                    "bg-blue-100 dark:bg-blue-900 text-blue-800 dark:text-blue-200 font-semibold",
                  @current_project_id != project.id &&
                    "text-slate-900 dark:text-slate-100 hover:bg-slate-100 dark:hover:bg-slate-700"
                ]}
              >
                <div class="flex items-center space-x-2 truncate">
                  <.icon
                    name="pi-folder-fill"
                    class="h-4 w-4 text-blue-600 dark:text-blue-500 shrink-0"
                  />
                  <span class="truncate">{project.name}</span>
                </div>
                <span
                  :if={project.key}
                  class="text-[10px] font-mono text-slate-500 dark:text-slate-400 shrink-0 ml-2"
                >
                  {project.key}
                </span>
              </button>
            </div>
          </div>
        </div>
      </div>

      <!-- Right Group: New Issue & Theme Toggle -->
      <div class="flex items-center space-x-2">
        <!-- New Issue Button -->
        <button
          type="button"
          id="global-capture-idea-button"
          data-qa="global_capture_idea_button"
          phx-click={CaptureIssueModal.open()}
          title="New Issue (⌘N)"
          aria-label="New Issue (⌘N)"
          class="inline-flex items-center space-x-1.5 h-8 px-3 rounded-lg bg-blue-100 dark:bg-blue-900 hover:opacity-90 text-blue-800 dark:text-blue-200 text-xs font-semibold shadow-xs transition-opacity"
        >
          <.icon name="pi-plus-circle-fill" class="h-4 w-4" />
          <span class="hidden sm:inline">New Issue</span>
        </button>

        <!-- Theme Toggle Button -->
        <button
          type="button"
          id="theme-toggle-button"
          data-qa="theme_toggle_button"
          phx-hook="Theme"
          title={if @theme == "dark", do: "Switch to Light mode", else: "Switch to Dark mode"}
          aria-label={if @theme == "dark", do: "Switch to Light mode", else: "Switch to Dark mode"}
          class="flex items-center justify-center h-8 w-8 rounded-lg hover:bg-slate-100 dark:hover:bg-slate-700 text-slate-900 dark:text-slate-100 transition-colors"
        >
          <.icon :if={@theme == "dark"} name="pi-sun" class="h-4 w-4 text-amber-400" />
          <.icon :if={@theme != "dark"} name="pi-moon" class="h-4 w-4 text-slate-700" />
        </button>

        <!-- User Menu Button -->
        <.link
          navigate={~p"/settings/connected-accounts"}
          id="user-menu-button"
          data-qa="user-menu"
          title="User menu"
          aria-label="User menu"
          class="flex items-center justify-center h-8 w-8 rounded-lg hover:bg-slate-100 dark:hover:bg-slate-700 text-slate-900 dark:text-slate-100 transition-colors"
        >
          <.icon name="pi-user-circle" class="h-4 w-4 text-slate-500 dark:text-slate-400" />
        </.link>

        <!-- Sign Out Button. Ends the Rail session; the GitHub account it was signed in with is untouched. -->
        <.link
          href={~p"/auth/logout"}
          id="sign-out-button"
          data-qa="sign_out"
          title="Sign out of Rail"
          aria-label="Sign out of Rail"
          class="flex items-center justify-center h-8 w-8 rounded-lg hover:bg-slate-100 dark:hover:bg-slate-700 text-slate-900 dark:text-slate-100 transition-colors"
        >
          <.icon name="pi-sign-out" class="h-4 w-4 text-slate-500 dark:text-slate-400" />
        </.link>
      </div>

      <.live_component
        module={CaptureIssueModal}
        id={CaptureIssueModal.id()}
        current_scope={@current_scope}
        projects={@projects}
        current_project_id={@current_project_id}
      />
    </header>
    """
  end

  defp destination_slug(:overview), do: "overview"
  defp destination_slug(:issues), do: "issues"
  defp destination_slug(:settings), do: "settings"
  defp destination_slug(other), do: to_string(other)

  defp section_title(:overview), do: "Overview"
  defp section_title(:issues), do: "Issues"
  defp section_title(:sandboxes), do: "Sandboxes"
  defp section_title(:triage), do: "Triage"
  defp section_title(:learnings), do: "Learnings"

  defp section_title(section)
       when section in [
              :settings,
              :connected_accounts,
              :projects,
              :linear_workspaces,
              :users,
              :roles,
              :backends,
              :mcp_servers,
              :slack_workspaces
            ], do: "Settings"

  defp section_title(:tasks), do: "Task"
  defp section_title(_other), do: "Rail"
end
