defmodule RailWeb.Hooks.NavHook do
  @moduledoc false
  use RailWeb, :live_view

  alias Rail.Pipeline
  alias Rail.Projects
  alias Rail.Users
  alias Rail.Users.Schemas.User

  def on_mount(:default, params, _session, socket) do
    scope = socket.assigns.current_scope
    projects = Projects.list_projects(scope)

    attention_count =
      if projects == [] do
        0
      else
        count_attention(scope, projects)
      end

    url_project =
      case Map.get(params, "project") do
        id when is_binary(id) and id != "" -> id
        _other -> nil
      end

    saved_project =
      if is_nil(url_project) and is_struct(scope.user, User) do
        scope.user.last_project_filter
      end

    current_project_id = url_project || saved_project

    if connected?(socket) do
      subscribe_livesync(current_project_id)
      Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline_changed")
    end

    socket =
      socket
      |> assign(:is_rail_extended, true)
      |> assign(:theme, "dark")
      |> assign(:show_project_switcher, false)
      |> assign(:show_new_issue_modal, false)
      |> assign(:projects, projects)
      |> assign(:attention_count, attention_count)
      |> assign(:current_project_id, current_project_id)
      |> assign(:current_section, :overview)
      |> attach_hook(:nav_handle_params, :handle_params, &handle_nav_params/3)
      |> attach_hook(:nav_handle_events, :handle_event, &handle_nav_events/3)
      |> attach_hook(:nav_handle_info, :handle_info, &handle_nav_info/2)

    {:cont, socket}
  end

  defp handle_nav_params(params, uri, socket) do
    project_id =
      case Map.get(params, "project") do
        id when is_binary(id) and id != "" -> id
        _other -> nil
      end

    current_path = URI.parse(uri).path

    if socket.assigns[:current_scope] do
      Users.set_project_filter(socket.assigns.current_scope, project_id)
    end

    if connected?(socket) and project_id != socket.assigns[:current_project_id] do
      subscribe_livesync(project_id)
    end

    socket =
      socket
      |> assign(:current_project_id, project_id)
      |> assign(:current_path, current_path)

    {:cont, socket}
  end

  defp handle_nav_events("toggle_rail", _params, socket) do
    socket = assign(socket, :is_rail_extended, not socket.assigns.is_rail_extended)
    {:halt, socket}
  end

  defp handle_nav_events("toggle_theme", _params, socket) do
    new_theme = if socket.assigns.theme == "dark", do: "light", else: "dark"
    socket = assign(socket, :theme, new_theme)
    {:halt, socket}
  end

  defp handle_nav_events("theme_changed", %{"theme" => theme}, socket) do
    socket = assign(socket, :theme, theme)
    {:halt, socket}
  end

  defp handle_nav_events("toggle_project_switcher", _params, socket) do
    socket = assign(socket, :show_project_switcher, not socket.assigns.show_project_switcher)
    {:halt, socket}
  end

  defp handle_nav_events("close_project_switcher", _params, socket) do
    socket = assign(socket, :show_project_switcher, false)
    {:halt, socket}
  end

  defp handle_nav_events("select_project", %{"project_id" => project_id}, socket) do
    path = socket.assigns[:current_path] || "/"

    target =
      if project_id in [nil, ""] do
        path
      else
        "#{path}?project=#{project_id}"
      end

    socket =
      socket
      |> assign(:show_project_switcher, false)
      |> push_patch(to: target)

    {:halt, socket}
  end

  defp handle_nav_events("open_new_issue", _params, socket) do
    socket = assign(socket, :show_new_issue_modal, true)
    {:halt, socket}
  end

  defp handle_nav_events("close_new_issue", _params, socket) do
    socket = assign(socket, :show_new_issue_modal, false)
    {:halt, socket}
  end

  defp handle_nav_events(_event, _params, socket) do
    {:cont, socket}
  end

  defp handle_nav_info({:live_sync, _data}, socket) do
    {:cont, refresh_nav_state(socket)}
  end

  defp handle_nav_info(:pipeline_changed, socket) do
    {:cont, refresh_nav_state(socket)}
  end

  defp handle_nav_info(%{event: "pipeline_changed"}, socket) do
    {:cont, refresh_nav_state(socket)}
  end

  defp handle_nav_info(_msg, socket) do
    {:cont, socket}
  end

  defp refresh_nav_state(socket) do
    scope = socket.assigns.current_scope
    projects = Projects.list_projects(scope)
    attention_count = count_attention(scope, projects)

    socket
    |> assign(:projects, projects)
    |> assign(:attention_count, attention_count)
  end

  defp count_attention(scope, projects) do
    tasks =
      Enum.flat_map(projects, fn project ->
        Pipeline.list_tasks(scope, project.id)
      end)

    Enum.count(tasks, &Rail.Domain.OverviewQueue.needs_attention?/1)
  end

  defp subscribe_livesync(nil) do
    LiveSync.Replication.subscribe("live_sync:all")
  end

  defp subscribe_livesync(project_id) do
    LiveSync.Replication.subscribe("live_sync:#{project_id}")
  end
end
