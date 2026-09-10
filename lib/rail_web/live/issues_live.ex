defmodule RailWeb.IssuesLive do
  @moduledoc false
  use RailWeb, :live_view

  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Issues")
      |> assign(:current_section, :issues)

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
      |> assign(:page_title, "Issues")
      |> assign(:current_section, :issues)
      |> assign(:current_project_id, project_id)

    {:noreply, socket}
  end

  def render(assigns) do
    ~H"""
    <div id="issues-view" data-qa="issues-view" class="space-y-6">
      <div class="flex items-center justify-between" id="issues-header">
        <h1
          class="text-2xl font-bold tracking-tight text-[var(--color-on-surface)]"
          id="issues-title"
          data-qa="issues_title"
        >
          Issues
        </h1>
      </div>

      <div class="m3-card p-6" id="issues-content">
        <p class="text-sm text-[var(--color-outline)]" id="issues-placeholder">
          Linear issues and backlog tasks across projects will appear here.
        </p>
      </div>
    </div>
    """
  end
end
