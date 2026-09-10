defmodule RailWeb.OverviewLive do
  @moduledoc false
  use RailWeb, :live_view

  alias Rail.Pipeline
  alias Rail.Projects

  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Overview")
      |> assign(:current_section, :overview)
      |> assign(:running_count, 0)

    {:ok, socket}
  end

  def handle_params(params, _uri, socket) do
    project_id =
      case Map.get(params, "project") do
        id when is_binary(id) and id != "" -> id
        _other -> nil
      end

    scope = socket.assigns[:current_scope]
    running_count = count_running(scope, project_id)

    socket =
      socket
      |> assign(:page_title, "Overview")
      |> assign(:current_section, :overview)
      |> assign(:current_project_id, project_id)
      |> assign(:running_count, running_count)

    {:noreply, socket}
  end

  def render(assigns) do
    ~H"""
    <div id="overview-view" data-qa="overview-view" class="space-y-6">
      <div class="flex items-center space-x-3" id="overview-header">
        <h1
          class="text-2xl font-bold tracking-tight text-[var(--color-on-surface)]"
          id="overview-title"
          data-qa="overview_title"
        >
          Overview
        </h1>
        <span
          id="running-agent-count-pill"
          data-qa="running_agent_count_pill"
          class="px-2.5 py-1 rounded-full text-xs font-semibold bg-[var(--color-surface-container-highest)] text-[var(--color-on-surface)]"
        >
          {running_agents_label(@running_count)}
        </span>
      </div>

      <div class="m3-card p-6" id="overview-content">
        <p class="text-sm text-[var(--color-outline)]" id="overview-placeholder">
          Agent fleet activity, active tasks, and human decisions queue will appear here.
        </p>
      </div>
    </div>
    """
  end

  def handle_info(:pipeline_changed, socket) do
    running_count = count_running(socket.assigns[:current_scope], socket.assigns[:current_project_id])
    {:noreply, assign(socket, :running_count, running_count)}
  end

  def handle_info(%{event: "pipeline_changed"}, socket) do
    running_count = count_running(socket.assigns[:current_scope], socket.assigns[:current_project_id])
    {:noreply, assign(socket, :running_count, running_count)}
  end

  def handle_info({:live_sync, _data}, socket) do
    running_count = count_running(socket.assigns[:current_scope], socket.assigns[:current_project_id])
    {:noreply, assign(socket, :running_count, running_count)}
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  defp count_running(scope, nil) do
    projects = Projects.list_projects(scope)

    Enum.reduce(projects, 0, fn project, acc ->
      tasks = Pipeline.list_tasks(scope, project.id, stage_state: :running)
      acc + length(tasks)
    end)
  end

  defp count_running(scope, project_id) do
    tasks = Pipeline.list_tasks(scope, project_id, stage_state: :running)
    length(tasks)
  end

  defp running_agents_label(1), do: "1 agent running"
  defp running_agents_label(n), do: "#{n} agents running"
end
