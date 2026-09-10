defmodule RailWeb.Components.SettingsNav do
  @moduledoc false
  use RailWeb, :html

  alias Rail.Scope

  attr :current_scope, :map, required: true
  attr :active_tab, :atom, required: true

  def settings_nav(assigns) do
    ~H"""
    <div class="border-b border-zinc-200" id="settings-nav">
      <nav class="-mb-px flex space-x-8" aria-label="Tabs" id="settings-tabs">
        <.link
          navigate={~p"/settings/connected-accounts"}
          class={[
            @active_tab == :connected_accounts && "border-indigo-500 text-indigo-600 font-semibold",
            @active_tab != :connected_accounts &&
              "border-transparent text-zinc-500 hover:border-zinc-300 hover:text-zinc-700",
            "whitespace-nowrap border-b-2 py-4 px-1 text-sm font-medium"
          ]}
          id="tab-connected-accounts"
        >
          Connected Accounts
        </.link>

        <.link
          navigate={~p"/settings/appearance"}
          class={[
            @active_tab == :appearance && "border-indigo-500 text-indigo-600 font-semibold",
            @active_tab != :appearance &&
              "border-transparent text-zinc-500 hover:border-zinc-300 hover:text-zinc-700",
            "whitespace-nowrap border-b-2 py-4 px-1 text-sm font-medium"
          ]}
          id="tab-appearance"
        >
          Appearance
        </.link>

        <.link
          :if={Scope.admin?(@current_scope)}
          navigate={~p"/settings/projects"}
          class={[
            @active_tab == :projects && "border-indigo-500 text-indigo-600 font-semibold",
            @active_tab != :projects &&
              "border-transparent text-zinc-500 hover:border-zinc-300 hover:text-zinc-700",
            "whitespace-nowrap border-b-2 py-4 px-1 text-sm font-medium"
          ]}
          id="tab-projects"
        >
          Projects
        </.link>

        <.link
          :if={Scope.admin?(@current_scope)}
          navigate={~p"/settings/linear-workspace"}
          class={[
            @active_tab == :linear_workspace && "border-indigo-500 text-indigo-600 font-semibold",
            @active_tab != :linear_workspace &&
              "border-transparent text-zinc-500 hover:border-zinc-300 hover:text-zinc-700",
            "whitespace-nowrap border-b-2 py-4 px-1 text-sm font-medium"
          ]}
          id="tab-linear-workspace"
        >
          Linear Workspace
        </.link>

        <.link
          :if={Scope.admin?(@current_scope)}
          navigate={~p"/settings/users"}
          class={[
            @active_tab == :users && "border-indigo-500 text-indigo-600 font-semibold",
            @active_tab != :users &&
              "border-transparent text-zinc-500 hover:border-zinc-300 hover:text-zinc-700",
            "whitespace-nowrap border-b-2 py-4 px-1 text-sm font-medium"
          ]}
          id="tab-users"
        >
          Users
        </.link>

        <.link
          :if={Scope.admin?(@current_scope)}
          navigate={~p"/settings/roles"}
          class={[
            @active_tab == :roles && "border-indigo-500 text-indigo-600 font-semibold",
            @active_tab != :roles &&
              "border-transparent text-zinc-500 hover:border-zinc-300 hover:text-zinc-700",
            "whitespace-nowrap border-b-2 py-4 px-1 text-sm font-medium"
          ]}
          id="tab-roles"
        >
          Roles
        </.link>
      </nav>
    </div>
    """
  end
end
