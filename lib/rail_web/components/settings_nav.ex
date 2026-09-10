defmodule RailWeb.Components.SettingsNav do
  @moduledoc false
  use RailWeb, :html

  alias Rail.Scope

  attr :current_scope, :map, required: true
  attr :active_tab, :atom, required: true

  def settings_nav(assigns) do
    ~H"""
    <div
      class="border-b border-slate-200 dark:border-slate-700"
      id="settings-nav"
      data-qa="settings-nav"
    >
      <nav class="-mb-px flex space-x-8" aria-label="Tabs" id="settings-tabs">
        <.link
          navigate={~p"/settings/connected-accounts"}
          class={[
            @active_tab == :connected_accounts && "border-indigo-500 text-indigo-600 font-semibold",
            @active_tab != :connected_accounts &&
              "border-transparent text-slate-500 dark:text-slate-400 hover:border-slate-500 dark:hover:border-slate-400 hover:text-slate-900 dark:hover:text-slate-100",
            "whitespace-nowrap border-b-2 py-4 px-1 text-sm font-medium"
          ]}
          id="tab-connected-accounts"
          data-qa="settings-tab"
        >
          Connected Accounts
        </.link>

        <.link
          :if={Scope.admin?(@current_scope)}
          navigate={~p"/settings/backends"}
          class={[
            @active_tab == :backends && "border-indigo-500 text-indigo-600 font-semibold",
            @active_tab != :backends &&
              "border-transparent text-slate-500 dark:text-slate-400 hover:border-slate-500 dark:hover:border-slate-400 hover:text-slate-900 dark:hover:text-slate-100",
            "whitespace-nowrap border-b-2 py-4 px-1 text-sm font-medium"
          ]}
          id="tab-backends"
          data-qa="settings-tab"
        >
          Backends
        </.link>

        <.link
          :if={Scope.admin?(@current_scope)}
          navigate={~p"/settings/projects"}
          class={[
            @active_tab == :projects && "border-indigo-500 text-indigo-600 font-semibold",
            @active_tab != :projects &&
              "border-transparent text-slate-500 dark:text-slate-400 hover:border-slate-500 dark:hover:border-slate-400 hover:text-slate-900 dark:hover:text-slate-100",
            "whitespace-nowrap border-b-2 py-4 px-1 text-sm font-medium"
          ]}
          id="tab-projects"
          data-qa="settings-tab"
        >
          Projects
        </.link>

        <.link
          :if={Scope.admin?(@current_scope)}
          navigate={~p"/settings/linear-workspace"}
          class={[
            @active_tab == :linear_workspace && "border-indigo-500 text-indigo-600 font-semibold",
            @active_tab != :linear_workspace &&
              "border-transparent text-slate-500 dark:text-slate-400 hover:border-slate-500 dark:hover:border-slate-400 hover:text-slate-900 dark:hover:text-slate-100",
            "whitespace-nowrap border-b-2 py-4 px-1 text-sm font-medium"
          ]}
          id="tab-linear-workspace"
          data-qa="settings-tab"
        >
          Linear Workspace
        </.link>

        <.link
          :if={Scope.admin?(@current_scope)}
          navigate={~p"/settings/users"}
          class={[
            @active_tab == :users && "border-indigo-500 text-indigo-600 font-semibold",
            @active_tab != :users &&
              "border-transparent text-slate-500 dark:text-slate-400 hover:border-slate-500 dark:hover:border-slate-400 hover:text-slate-900 dark:hover:text-slate-100",
            "whitespace-nowrap border-b-2 py-4 px-1 text-sm font-medium"
          ]}
          id="tab-users"
          data-qa="settings-tab"
        >
          Users
        </.link>

        <.link
          :if={Scope.admin?(@current_scope)}
          navigate={~p"/settings/roles"}
          class={[
            @active_tab == :roles && "border-indigo-500 text-indigo-600 font-semibold",
            @active_tab != :roles &&
              "border-transparent text-slate-500 dark:text-slate-400 hover:border-slate-500 dark:hover:border-slate-400 hover:text-slate-900 dark:hover:text-slate-100",
            "whitespace-nowrap border-b-2 py-4 px-1 text-sm font-medium"
          ]}
          id="tab-roles"
          data-qa="settings-tab"
        >
          Roles
        </.link>
      </nav>
    </div>
    """
  end
end
