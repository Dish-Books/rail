defmodule RailWeb.CliAccountsLive do
  @moduledoc false
  use RailWeb, :live_view

  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "CLI Accounts")
      |> assign(:current_section, :cli_accounts)

    {:ok, socket}
  end

  def handle_params(params, _uri, socket) do
    project_id =
      case Map.get(params, "project") do
        id when is_binary(id) and id != "" -> id
        _other -> nil
      end

    socket =
      socket
      |> assign(:page_title, "CLI Accounts")
      |> assign(:current_section, :cli_accounts)
      |> assign(:current_project_id, project_id)

    {:noreply, socket}
  end

  def render(assigns) do
    ~H"""
    <div id="cli-accounts-view" data-qa="cli-accounts-view" class="space-y-6">
      <div class="flex items-center justify-between" id="cli-accounts-header">
        <h1
          class="text-2xl font-bold tracking-tight text-[var(--color-on-surface)]"
          id="cli-accounts-title"
          data-qa="cli_accounts_title"
        >
          CLI Accounts
        </h1>
      </div>

      <div class="m3-card p-6" id="cli-accounts-content">
        <p class="text-sm text-[var(--color-outline)]" id="cli-accounts-placeholder">
          Agent runner node accounts, usage probes, and model registry will appear here.
        </p>
      </div>
    </div>
    """
  end
end
