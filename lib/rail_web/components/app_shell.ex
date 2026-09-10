defmodule RailWeb.Components.AppShell do
  @moduledoc false
  use RailWeb, :html

  import RailWeb.Components.CaptureIssueModal, only: [capture_issue_modal: 1]

  attr :current_section, :atom, required: true
  attr :is_rail_extended, :boolean, default: true
  attr :attention_count, :integer, default: 0
  attr :current_project_id, :string, default: nil

  def nav_rail(assigns) do
    ~H"""
    <aside
      id="navigation-rail"
      data-qa="navigation_rail"
      class={[
        "nav-rail-transition flex flex-col justify-between h-full shrink-0 border-r border-[var(--color-border)] bg-[var(--color-surface-container)] select-none",
        @is_rail_extended && "w-56",
        !@is_rail_extended && "w-16"
      ]}
    >
      <!-- Top Group: Logo and Destinations -->
      <div class="flex flex-col space-y-4 p-3">
        <!-- Brand / Leading -->
        <div class="flex items-center px-2 py-2" id="app-brand">
          <div class="flex items-center justify-center h-9 w-9 rounded-lg bg-[var(--color-primary-container)] text-[var(--color-on-primary-container)] shrink-0">
            <.icon name="layers" class="h-5 w-5" />
          </div>
          <span
            :if={@is_rail_extended}
            class="ml-3 text-sm font-bold tracking-widest text-[var(--color-on-surface)] uppercase"
            id="brand-name"
          >
            Rail
          </span>
        </div>

        <!-- Destinations List -->
        <nav class="flex flex-col space-y-1" id="nav-destinations" aria-label="Main Navigation">
          <.nav_destination
            section={:overview}
            active={@current_section == :overview}
            is_extended={@is_rail_extended}
            label="Overview"
            icon_active="dashboard"
            icon_inactive="dashboard_outlined"
            href={nav_path("/", @current_project_id)}
            attention_count={@attention_count}
          />

          <.nav_destination
            section={:issues}
            active={@current_section == :issues}
            is_extended={@is_rail_extended}
            label="Issues"
            icon_active="lightbulb"
            icon_inactive="lightbulb_outline"
            href={nav_path("/issues", @current_project_id)}
            attention_count={0}
          />

          <.nav_destination
            section={:cli_accounts}
            active={@current_section == :cli_accounts}
            is_extended={@is_rail_extended}
            label="CLI Accounts"
            icon_active="account_circle"
            icon_inactive="account_circle_outlined"
            href={nav_path("/cli-accounts", @current_project_id)}
            attention_count={0}
          />

          <.nav_destination
            section={:settings}
            active={
              @current_section in [
                :settings,
                :connected_accounts,
                :projects,
                :linear_workspace,
                :appearance,
                :users,
                :roles
              ]
            }
            is_extended={@is_rail_extended}
            label="Settings"
            icon_active="settings"
            icon_inactive="settings_outlined"
            href={nav_path("/settings/connected-accounts", @current_project_id)}
            attention_count={0}
          />
        </nav>
      </div>

      <!-- Bottom Group: Rail Toggle -->
      <div class="p-3 border-t border-[var(--color-border)]">
        <button
          type="button"
          id="rail-toggle"
          data-qa="rail_toggle"
          phx-click="toggle_rail"
          title={if @is_rail_extended, do: "Collapse sidebar", else: "Expand sidebar"}
          aria-label={if @is_rail_extended, do: "Collapse sidebar", else: "Expand sidebar"}
          class="flex items-center justify-center w-full h-10 rounded-lg hover:bg-[var(--color-surface-container-high)] text-[var(--color-outline)] hover:text-[var(--color-on-surface)] transition-colors"
        >
          <.icon :if={@is_rail_extended} name="chevron_left" class="h-5 w-5" />
          <.icon :if={!@is_rail_extended} name="chevron_right" class="h-5 w-5" />
        </button>
      </div>
    </aside>
    """
  end

  attr :section, :atom, required: true
  attr :active, :boolean, required: true
  attr :is_extended, :boolean, required: true
  attr :label, :string, required: true
  attr :icon_active, :string, required: true
  attr :icon_inactive, :string, required: true
  attr :href, :string, required: true
  attr :attention_count, :integer, default: 0

  def nav_destination(assigns) do
    ~H"""
    <.link
      navigate={@href}
      id={"nav-#{destination_slug(@section)}"}
      data-qa={"nav_#{destination_slug(@section)}"}
      data-active={if @active, do: "true", else: "false"}
      title={@label}
      class={[
        "flex items-center h-11 rounded-xl transition-colors relative group",
        @is_extended && "px-3",
        !@is_extended && "justify-center px-0",
        @active &&
          "bg-[var(--color-primary-container)] text-[var(--color-on-primary-container)] font-semibold shadow-xs",
        !@active &&
          "text-[var(--color-outline)] hover:bg-[var(--color-surface-container-high)] hover:text-[var(--color-on-surface)]"
      ]}
    >
      <div class="relative flex items-center justify-center shrink-0">
        <.icon :if={@active} name={@icon_active} class="h-5 w-5" />
        <.icon :if={!@active} name={@icon_inactive} class="h-5 w-5" />
        <span
          :if={@attention_count > 0}
          id="attention-badge"
          data-qa="attention_badge"
          class="absolute -top-1.5 -right-1.5 flex h-4 min-w-4 items-center justify-center rounded-full bg-amber-600 px-1 text-[10px] font-bold text-white ring-2 ring-[var(--color-surface-container)]"
        >
          {@attention_count}
        </span>
      </div>
      <span
        :if={@is_extended}
        class="ml-3 text-sm truncate"
        id={"nav-label-#{destination_slug(@section)}"}
      >
        {@label}
      </span>
    </.link>
    """
  end

  attr :current_section, :atom, required: true
  attr :current_project_id, :string, default: nil
  attr :projects, :list, default: []
  attr :theme, :string, default: "dark"
  attr :show_project_switcher, :boolean, default: false
  attr :show_new_issue_modal, :boolean, default: false
  attr :capture_ask, :string, default: ""
  attr :capture_project_id, :string, default: nil
  attr :capture_priority, :any, default: :medium
  attr :capture_error, :string, default: nil
  attr :capture_submitting, :boolean, default: false

  def top_app_bar(assigns) do
    active_projects = Enum.filter(assigns.projects, & &1.active)
    selected_project = Enum.find(assigns.projects, &(&1.id == assigns.current_project_id))
    assigns = assign(assigns, :active_projects, active_projects)
    assigns = assign(assigns, :selected_project, selected_project)

    ~H"""
    <header
      id="top-app-bar"
      data-qa="top_app_bar"
      class="h-[52px] px-5 flex items-center justify-between border-b border-[var(--color-border)] bg-[var(--color-surface)] shrink-0 z-20"
    >
      <!-- Left Group: Section Title & Project Filter -->
      <div class="flex items-center space-x-4">
        <h1
          id="section-title"
          data-qa="section_title"
          class="text-sm font-semibold tracking-tight text-[var(--color-on-surface)] whitespace-nowrap"
        >
          {section_title(@current_section)}
        </h1>

        <!-- Project Switcher Pill Button -->
        <div class="relative">
          <button
            type="button"
            id="project-switcher-button"
            data-qa="project_switcher_button"
            phx-click="toggle_project_switcher"
            class="flex items-center space-x-1.5 px-2.5 py-1 rounded-lg border border-[var(--color-outline-variant)] bg-[var(--color-surface-container-high)] hover:bg-[var(--color-surface-container-highest)] text-xs font-medium text-[var(--color-on-surface)] transition-colors shadow-xs"
          >
            <.icon name="folder_outlined" class="h-4 w-4 text-[var(--color-primary)]" />
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
              class="ml-1 px-1.5 py-0.2 rounded-full text-[10px] font-semibold bg-[var(--color-surface-container-highest)] text-[var(--color-on-surface)] ring-1 ring-inset ring-[var(--color-outline-variant)]"
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
            <.icon name="unfold_more" class="h-3.5 w-3.5 text-[var(--color-outline)]" />
          </button>

          <!-- Project Switcher Dropdown Dialog -->
          <div
            :if={@show_project_switcher}
            id="project-switcher-dialog"
            data-qa="project_switcher_dialog"
            class="absolute left-0 mt-2 w-64 rounded-xl border border-[var(--color-border)] bg-[var(--color-surface-container)] p-1.5 shadow-xl z-50 focus:outline-none"
          >
            <div class="px-2 py-1.5 text-[11px] font-semibold uppercase tracking-wider text-[var(--color-outline)]">
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
                  "bg-[var(--color-primary-container)] text-[var(--color-on-primary-container)] font-semibold",
                not is_nil(@selected_project) &&
                  "text-[var(--color-on-surface)] hover:bg-[var(--color-surface-container-high)]"
              ]}
            >
              <div class="flex items-center space-x-2">
                <.icon name="folder_outlined" class="h-4 w-4 text-[var(--color-primary)]" />
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
                    "bg-[var(--color-primary-container)] text-[var(--color-on-primary-container)] font-semibold",
                  @current_project_id != project.id &&
                    "text-[var(--color-on-surface)] hover:bg-[var(--color-surface-container-high)]"
                ]}
              >
                <div class="flex items-center space-x-2 truncate">
                  <.icon name="folder" class="h-4 w-4 text-[var(--color-primary)] shrink-0" />
                  <span class="truncate">{project.name}</span>
                </div>
                <span
                  :if={project.linear_team_key}
                  class="text-[10px] font-mono text-[var(--color-outline)] shrink-0 ml-2"
                >
                  {project.linear_team_key}
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
          phx-click="open_new_issue"
          title="New Issue (⌘N)"
          aria-label="New Issue (⌘N)"
          class="inline-flex items-center space-x-1.5 h-8 px-3 rounded-lg bg-[var(--color-primary-container)] hover:opacity-90 text-[var(--color-on-primary-container)] text-xs font-semibold shadow-xs transition-opacity"
        >
          <.icon name="add_circle" class="h-4 w-4" />
          <span class="hidden sm:inline">New Issue</span>
        </button>

        <!-- Theme Toggle Button -->
        <button
          type="button"
          id="theme-toggle-button"
          data-qa="theme_toggle_button"
          phx-click="toggle_theme"
          title={if @theme == "dark", do: "Switch to Light mode", else: "Switch to Dark mode"}
          aria-label={if @theme == "dark", do: "Switch to Light mode", else: "Switch to Dark mode"}
          class="flex items-center justify-center h-8 w-8 rounded-lg hover:bg-[var(--color-surface-container-high)] text-[var(--color-on-surface)] transition-colors"
        >
          <.icon :if={@theme == "dark"} name="light_mode" class="h-4 w-4 text-amber-400" />
          <.icon :if={@theme != "dark"} name="dark_mode" class="h-4 w-4 text-slate-700" />
        </button>
      </div>

      <!-- Capture Issue Modal -->
      <.capture_issue_modal
        visible={@show_new_issue_modal}
        projects={@projects}
        current_project_id={@current_project_id}
        capture_ask={@capture_ask}
        capture_project_id={@capture_project_id}
        capture_priority={@capture_priority}
        capture_error={@capture_error}
        capture_submitting={@capture_submitting}
      />
    </header>
    """
  end

  attr :name, :string, required: true
  attr :class, :string, default: "h-5 w-5"

  def icon(assigns) do
    ~H"""
    <span class={@class} aria-hidden="true">
      <svg
        :if={@name in ["layers"]}
        class="w-full h-full fill-current"
        viewBox="0 0 24 24"
      >
        <path d="M12 2L1 7l11 5 11-5-11-5zm0 8.5L3.5 7 12 3.1 20.5 7 12 10.5zM1 12l11 5 11-5-2.2-1-8.8 4-8.8-4L1 12zm0 5l11 5 11-5-2.2-1-8.8 4-8.8-4L1 17z" />
      </svg>

      <svg
        :if={@name in ["dashboard"]}
        class="w-full h-full fill-current"
        viewBox="0 0 24 24"
      >
        <path d="M3 13h8V3H3v10zm0 8h8v-6H3v6zm10 0h8V11h-8v10zm0-18v6h8V3h-8z" />
      </svg>

      <svg
        :if={@name in ["dashboard_outlined"]}
        class="w-full h-full fill-current"
        viewBox="0 0 24 24"
      >
        <path d="M19 3H5c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2zm-8 16H5v-6h6v6zm0-8H5V5h6v6zm8 8h-6v-8h6v8zm0-10h-6V5h6v4z" />
      </svg>

      <svg
        :if={@name in ["lightbulb"]}
        class="w-full h-full fill-current"
        viewBox="0 0 24 24"
      >
        <path d="M9 21c0 .55.45 1 1 1h4c.55 0 1-.45 1-1v-1H9v1zm3-19C8.14 2 5 5.14 5 9c0 2.38 1.19 4.47 3 5.74V17c0 .55.45 1 1 1h6c.55 0 1-.45 1-1v-2.26c1.81-1.27 3-3.36 3-5.74 0-3.86-3.14-7-7-7z" />
      </svg>

      <svg
        :if={@name in ["lightbulb_outline"]}
        class="w-full h-full fill-current"
        viewBox="0 0 24 24"
      >
        <path d="M9 21c0 .55.45 1 1 1h4c.55 0 1-.45 1-1v-1H9v1zm3-19C8.14 2 5 5.14 5 9c0 2.38 1.19 4.47 3 5.74V17c0 .55.45 1 1 1h6c.55 0 1-.45 1-1v-2.26c1.81-1.27 3-3.36 3-5.74 0-3.86-3.14-7-7-7zm2.85 11.1l-.85.6V16h-4v-2.3l-.85-.6C7.8 12.16 7 10.63 7 9c0-2.76 2.24-5 5-5s5 2.24 5 5c0 1.63-.8 3.16-2.15 4.1z" />
      </svg>

      <svg
        :if={@name in ["account_circle"]}
        class="w-full h-full fill-current"
        viewBox="0 0 24 24"
      >
        <path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm0 3c1.66 0 3 1.34 3 3s-1.34 3-3 3-3-1.34-3-3 1.34-3 3-3zm0 14.2c-2.5 0-4.71-1.28-6-3.22.03-1.99 4-3.08 6-3.08 1.99 0 5.97 1.09 6 3.08-1.29 1.94-3.5 3.22-6 3.22z" />
      </svg>

      <svg
        :if={@name in ["account_circle_outlined"]}
        class="w-full h-full fill-current"
        viewBox="0 0 24 24"
      >
        <path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm0 18c-4.41 0-8-3.59-8-8s3.59-8 8-8 8 3.59 8 8-3.59 8-8 8zm0-14c-2.21 0-4 1.79-4 4s1.79 4 4 4 4-1.79 4-4-1.79-4-4-4zm0 6c-1.1 0-2-.9-2-2s.9-2 2-2 2 .9 2 2-.9 2-2 2zm0 3.5c-2.33 0-4.32 1.1-5.36 2.77.82.59 1.82.93 2.9.93h4.92c1.08 0 2.08-.34 2.9-.93-1.04-1.67-3.03-2.77-5.36-2.77z" />
      </svg>

      <svg
        :if={@name in ["settings"]}
        class="w-full h-full fill-current"
        viewBox="0 0 24 24"
      >
        <path d="M19.14 12.94c.04-.3.06-.61.06-.94 0-.32-.02-.64-.07-.94l2.03-1.58c.18-.14.23-.41.12-.61l-1.92-3.32c-.12-.22-.37-.29-.59-.22l-2.39.96c-.5-.38-1.03-.7-1.62-.94l-.36-2.54c-.04-.24-.24-.41-.48-.41h-3.84c-.24 0-.43.17-.47.41l-.36 2.54c-.59.24-1.13.57-1.62.94l-2.39-.96c-.22-.08-.47 0-.59.22L2.74 8.87c-.12.21-.08.47.12.61l2.03 1.58c-.05.3-.09.63-.09.94s.02.64.07.94l-2.03 1.58c-.18.14-.23.41-.12.61l1.92 3.32c.12.22.37.29.59.22l2.39-.96c.5.38 1.03.7 1.62.94l.36 2.54c.05.24.24.41.48.41h3.84c.24 0 .44-.17.47-.41l.36-2.54c.59-.24 1.13-.56 1.62-.94l2.39.96c.22.08.47 0 .59-.22l1.92-3.32c.12-.22.07-.47-.12-.61l-2.01-1.58zM12 15.6c-1.98 0-3.6-1.62-3.6-3.6s1.62-3.6 3.6-3.6 3.6 1.62 3.6 3.6-1.62 3.6-3.6 3.6z" />
      </svg>

      <svg
        :if={@name in ["settings_outlined"]}
        class="w-full h-full fill-current"
        viewBox="0 0 24 24"
      >
        <path d="M19.43 12.98c.04-.32.07-.64.07-.98s-.03-.66-.07-.98l2.11-1.65c.19-.15.24-.42.12-.64l-2-3.46c-.12-.22-.39-.3-.61-.22l-2.49 1c-.52-.4-1.08-.73-1.69-.98l-.38-2.65A.488.488 0 0 0 14 2h-4c-.25 0-.46.18-.49.42l-.38 2.65c-.61.25-1.17.59-1.69.98l-2.49-1c-.23-.09-.49 0-.61.22l-2 3.46c-.13.22-.07.49.12.64l2.11 1.65c-.04.32-.07.65-.07.98s.03.66.07.98l-2.11 1.65c-.19.15-.24.42-.12.64l2 3.46c.12.22.39.3.61.22l2.49-1c.52.4 1.08.73 1.69.98l.38 2.65c.03.24.24.42.49.42h4c.25 0 .46-.18.49-.42l.38-2.65c.61-.25 1.17-.59 1.69-.98l2.49 1c.23.09.49 0 .61-.22l2-3.46c.12-.22.07-.49-.12-.64l-2.11-1.65zm-1.98-1.71c.04.31.05.52.05.73 0 .21-.02.43-.05.73l-.14 1.13.89.7 1.08.84-.7 1.21-1.27-.51-1.04-.42-.9.68c-.43.32-.84.56-1.25.73l-1.06.43-.16 1.13-.2 1.35h-1.4l-.2-1.35-.16-1.13-1.06-.43c-.43-.18-.83-.41-1.23-.71l-.91-.7-1.06.43-1.27.51-.7-1.21 1.08-.84.89-.7-.14-1.13c-.03-.31-.05-.52-.05-.73 0-.21.02-.43.05-.73l.14-1.13-.89-.7-1.08-.84.7-1.21 1.27.51 1.04.42.9-.68c.43-.32.84-.56 1.25-.73l1.06-.43.16-1.13.2-1.35h1.39l.2 1.35.16 1.13 1.06.43c.43.18.83.41 1.23.71l.91.7 1.06-.43 1.27-.51.7 1.21-1.07.85-.89.7.14 1.13zM12 8c-2.21 0-4 1.79-4 4s1.79 4 4 4 4-1.79 4-4-1.79-4-4-4zm0 6c-1.1 0-2-.9-2-2s.9-2 2-2 2 .9 2 2-.9 2-2 2z" />
      </svg>

      <svg
        :if={@name in ["chevron_left"]}
        class="w-full h-full fill-current"
        viewBox="0 0 24 24"
      >
        <path d="M15.41 7.41L14 6l-6 6 6 6 1.41-1.41L10.83 12z" />
      </svg>

      <svg
        :if={@name in ["chevron_right"]}
        class="w-full h-full fill-current"
        viewBox="0 0 24 24"
      >
        <path d="M10 6L8.59 7.41 13.17 12l-4.58 4.59L10 18l6-6z" />
      </svg>

      <svg
        :if={@name in ["folder"]}
        class="w-full h-full fill-current"
        viewBox="0 0 24 24"
      >
        <path d="M10 4H4c-1.1 0-1.99.9-1.99 2L2 18c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V8c0-1.1-.9-2-2-2h-8l-2-2z" />
      </svg>

      <svg
        :if={@name in ["folder_outlined"]}
        class="w-full h-full fill-current"
        viewBox="0 0 24 24"
      >
        <path d="M20 6h-8l-2-2H4c-1.1 0-1.99.9-1.99 2L2 18c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V8c0-1.1-.9-2-2-2zm0 12H4V8h16v10z" />
      </svg>

      <svg
        :if={@name in ["unfold_more"]}
        class="w-full h-full fill-current"
        viewBox="0 0 24 24"
      >
        <path d="M12 5.83L15.17 9l1.41-1.41L12 3 7.41 7.59 8.83 9 12 5.83zm0 12.34L8.83 15l-1.41 1.41L12 21l4.59-4.59L15.17 15 12 18.17z" />
      </svg>

      <svg
        :if={@name in ["add_circle"]}
        class="w-full h-full fill-current"
        viewBox="0 0 24 24"
      >
        <path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm5 11h-4v4h-2v-4H7v-2h4V7h2v4h4v2z" />
      </svg>

      <svg
        :if={@name in ["light_mode"]}
        class="w-full h-full fill-current"
        viewBox="0 0 24 24"
      >
        <path d="M12 7c-2.76 0-5 2.24-5 5s2.24 5 5 5 5-2.24 5-5-2.24-5-5-5zM2 13h2c.55 0 1-.45 1-1s-.45-1-1-1H2c-.55 0-1 .45-1 1s.45 1 1 1zm18 0h2c.55 0 1-.45 1-1s-.45-1-1-1h-2c-.55 0-1 .45-1 1s.45 1 1 1zM11 2v2c0 .55.45 1 1 1s1-.45 1-1V2c0-.55-.45-1-1-1s-1 .45-1 1zm0 18v2c0 .55.45 1 1 1s1-.45 1-1v-2c0-.55-.45-1-1-1s-1 .45-1 1zM5.99 4.58a.996.996 0 0 0-1.41 0 .996.996 0 0 0 0 1.41l1.06 1.06c.39.39 1.03.39 1.41 0s.39-1.03 0-1.41L5.99 4.58zm12.37 12.37a.996.996 0 0 0-1.41 0 .996.996 0 0 0 0 1.41l1.06 1.06c.39.39 1.03.39 1.41 0s.39-1.03 0-1.41l-1.06-1.06zm1.06-10.96a.996.996 0 0 0 0-1.41.996.996 0 0 0-1.41 0l-1.06 1.06c-.39.39-.39 1.03 0 1.41s1.03.39 1.41 0l1.06-1.06zM7.05 18.36a.996.996 0 0 0 0-1.41.996.996 0 0 0-1.41 0l-1.06 1.06c-.39.39-.39 1.03 0 1.41s1.03.39 1.41 0l1.06-1.06z" />
      </svg>

      <svg
        :if={@name in ["dark_mode"]}
        class="w-full h-full fill-current"
        viewBox="0 0 24 24"
      >
        <path d="M12 3c-4.97 0-9 4.03-9 9s4.03 9 9 9 9-4.03 9-9c0-.46-.04-.92-.1-1.36-.98 1.37-2.58 2.26-4.4 2.26-2.98 0-5.4-2.42-5.4-5.4 0-1.81.89-3.42 2.26-4.4-.44-.06-.9-.1-1.36-.1z" />
      </svg>

      <svg
        :if={@name in ["info_outline", "info"]}
        class="w-full h-full fill-current"
        viewBox="0 0 24 24"
      >
        <path d="M11 17h2v-6h-2v6zm1-15C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm0 18c-4.41 0-8-3.59-8-8s3.59-8 8-8 8 3.59 8 8-3.59 8-8 8zm-1-13h2v-2h-2v2z" />
      </svg>

      <svg
        :if={@name in ["check_circle_outline", "check_circle"]}
        class="w-full h-full fill-current"
        viewBox="0 0 24 24"
      >
        <path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm0 18c-4.41 0-8-3.59-8-8s3.59-8 8-8 8 3.59 8 8-3.59 8-8 8zm4.59-12.42L10 14.17l-2.59-2.58L6 13l4 4 8-8z" />
      </svg>

      <svg
        :if={@name in ["code", "terminal", "hero-command-line"]}
        class="w-full h-full fill-current"
        viewBox="0 0 24 24"
      >
        <path d="M9.4 16.6L4.8 12l4.6-4.6L8 6l-6 6 6 6 1.4-1.4zm5.2 0l4.6-4.6-4.6-4.6L16 6l6 6-6 6-1.4-1.4z" />
      </svg>

      <svg
        :if={@name in ["architecture", "account_tree"]}
        class="w-full h-full fill-current"
        viewBox="0 0 24 24"
      >
        <path d="M19 15v-3h-2v3h-3v2h3v3h2v-3h3v-2h-3zM7 9h2V6H7v3zm4-5H5v7h6V4zm8 0h-6v7h6V4zM9 18H7v-3h2v3zm2-5H5v7h6v-7z" />
      </svg>

      <svg
        :if={@name in ["palette", "brush", "design"]}
        class="w-full h-full fill-current"
        viewBox="0 0 24 24"
      >
        <path d="M12 3a9 9 0 0 0 0 18c.83 0 1.5-.67 1.5-1.5 0-.39-.15-.74-.39-1.01-.23-.26-.38-.61-.38-.99 0-.83.67-1.5 1.5-1.5H16c2.76 0 5-2.24 5-5 0-4.42-4.03-8-9-8zm-5.5 9c-.83 0-1.5-.67-1.5-1.5S5.67 9 6.5 9 8 9.67 8 10.5 7.33 12 6.5 12zm3-4C8.67 8 8 7.33 8 6.5S8.67 5 9.5 5s1.5.67 1.5 1.5S10.33 8 9.5 8zm5 0c-.83 0-1.5-.67-1.5-1.5S13.67 5 14.5 5s1.5.67 1.5 1.5S15.33 8 14.5 8zm3 4c-.83 0-1.5-.67-1.5-1.5S16.67 9 17.5 9s1.5.67 1.5 1.5-.67 1.5-1.5 1.5z" />
      </svg>

      <svg
        :if={@name in ["videocam", "movie", "demo"]}
        class="w-full h-full fill-current"
        viewBox="0 0 24 24"
      >
        <path d="M17 10.5V7c0-.55-.45-1-1-1H4c-.55 0-1 .45-1 1v10c0 .55.45 1 1 1h12c.55 0 1-.45 1-1v-3.5l4 4v-11l-4 4z" />
      </svg>

      <svg
        :if={@name in ["fact_check", "checklist", "qa"]}
        class="w-full h-full fill-current"
        viewBox="0 0 24 24"
      >
        <path d="M20 3H4c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2zm-9 14l-4-4 1.41-1.41L11 14.17l6.59-6.59L19 9l-8 8zm0-10H5V5h6v2zm8 0h-6V5h6v2zm0 4h-6V9h6v2z" />
      </svg>

      <svg
        :if={@name in ["chat"]}
        class="w-full h-full fill-current"
        viewBox="0 0 24 24"
      >
        <path d="M20 2H4c-1.1 0-1.99.9-1.99 2L2 22l4-4h14c1.1 0 2-.9 2-2V4c0-1.1-.9-2-2-2zM6 9h12v2H6V9zm8 5H6v-2h8v2zm4-6H6V6h12v2z" />
      </svg>

      <svg
        :if={@name in ["smart_toy", "robot", "agent"]}
        class="w-full h-full fill-current"
        viewBox="0 0 24 24"
      >
        <path d="M20 9V7c0-1.1-.9-2-2-2h-3c0-1.66-1.34-3-3-3S9 3.34 9 5H6c-1.1 0-2 .9-2 2v2c-1.66 0-3 1.34-3 3s1.34 3 3 3v4c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2v-4c1.66 0 3-1.34 3-3s-1.34-3-3-3zm-2 10H6V7h12v12zm-9-6c-.83 0-1.5-.67-1.5-1.5S8.17 10 9 10s1.5.67 1.5 1.5S9.83 13 9 13zm6 0c-.83 0-1.5-.67-1.5-1.5s.67-1.5 1.5-1.5 1.5.67 1.5 1.5-.67 1.5-1.5 1.5zm-7.5 3h9v1.5h-9V16z" />
      </svg>
    </span>
    """
  end

  defp destination_slug(:overview), do: "overview"
  defp destination_slug(:issues), do: "issues"
  defp destination_slug(:cli_accounts), do: "cli-accounts"
  defp destination_slug(:settings), do: "settings"
  defp destination_slug(other), do: to_string(other)

  defp section_title(:overview), do: "Overview"
  defp section_title(:issues), do: "Issues"
  defp section_title(:cli_accounts), do: "CLI Accounts"
  defp section_title(:settings), do: "Settings"
  defp section_title(:connected_accounts), do: "Settings"
  defp section_title(:projects), do: "Settings"
  defp section_title(:linear_workspace), do: "Settings"
  defp section_title(:tasks), do: "Task"
  defp section_title(_other), do: "Rail"

  defp nav_path(base_path, nil), do: base_path
  defp nav_path(base_path, ""), do: base_path
  defp nav_path(base_path, project_id), do: "#{base_path}?project=#{project_id}"
end
