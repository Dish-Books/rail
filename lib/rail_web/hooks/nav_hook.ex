defmodule RailWeb.Hooks.NavHook do
  @moduledoc false
  use RailWeb, :live_view

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Projects
  alias Rail.Scope
  alias Rail.Users
  alias Rail.Users.Schemas.User

  def on_mount(:default, params, _session, socket) do
    scope = socket.assigns.current_scope
    projects = Projects.list_projects()

    attention_count =
      if projects == [] do
        0
      else
        count_attention(projects)
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

    socket =
      socket
      |> assign(:is_rail_extended, true)
      |> assign(:theme, "dark")
      |> assign(:show_project_switcher, false)
      |> assign(:projects, projects)
      |> assign(:attention_count, attention_count)
      |> assign(:current_project_id, current_project_id)
      |> assign(:current_section, :overview)
      |> attach_hook(:nav_handle_params, :handle_params, &handle_nav_params/3)
      |> attach_hook(:nav_handle_events, :handle_event, &handle_nav_events/3)

    {:cont, socket}
  end

  defp handle_nav_params(params, uri, socket) do
    project_id =
      case Map.get(params, "project") do
        id when is_binary(id) and id != "" -> id
        _other -> nil
      end

    current_path = URI.parse(uri).path

    scope = socket.assigns[:current_scope]

    # Updating a user requires :users/:manage; the session's own user is already
    # authenticated by the router, so this self-update runs as the system.
    if scope && scope.user do
      Users.update_user(Scope.for_system(), scope.user, %{last_project_filter: project_id})
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

  defp handle_nav_events(_event, _params, socket) do
    {:cont, socket}
  end

  # What needs a human is counted in tasks, the same as the overview lists them:
  # one task waiting is one thing to do, however many runs it has behind it.
  defp count_attention(projects) do
    projects
    |> Enum.flat_map(fn project ->
      Pipeline.list_runs(project_id: project.id, preload: [:role, :questions, task: :issue])
    end)
    |> Enum.filter(&Run.needs_attention?/1)
    |> Enum.uniq_by(& &1.task_id)
    |> length()
  end
end
