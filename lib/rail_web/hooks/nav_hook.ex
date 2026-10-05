defmodule RailWeb.Hooks.NavHook do
  @moduledoc false
  use RailWeb, :live_view

  alias Rail.Pipeline
  alias Rail.Projects
  alias Rail.Scope
  alias Rail.Tools
  alias Rail.Triage

  def on_mount(:default, _params, session, socket) do
    scope = socket.assigns.current_scope
    projects = Projects.list_projects(scope)
    # A lost project stays in the session, so it comes back selected if access is granted again.
    current_project_id = Enum.find_value(projects, &(&1.id == session["selected_project_id"] && &1.id))

    socket =
      socket
      |> assign(:is_rail_extended, true)
      |> assign(:theme, "dark")
      |> assign(:show_project_switcher, false)
      |> assign(:projects, projects)
      |> assign(:attention_count, Pipeline.count_attention(project_id: Scope.project_ids(scope)))
      |> assign(:triage_count, Triage.count_triage_threads(project_id: Scope.project_ids(scope)).waiting)
      |> assign(:current_project_id, current_project_id)
      # What a page lists: the selected project, or else every project the user can see.
      |> assign(:project_filter, current_project_id || Scope.project_ids(scope))
      |> assign(:current_section, :overview)
      |> assign(:lost_backends, Enum.filter(Tools.list_backends(), & &1.session_lost_at))
      |> attach_hook(:nav_handle_params, :handle_params, &handle_nav_params/3)
      |> attach_hook(:nav_handle_events, :handle_event, &handle_nav_events/3)

    {:cont, socket}
  end

  defp handle_nav_params(params, uri, socket) do
    socket =
      socket
      |> assign(:current_path, URI.parse(uri).path)
      # The Overview's everyone's-work view survives a change of project.
      |> assign(:kept_params, if(params["everyone"] == "true", do: [everyone: true], else: []))

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

    kept_params = socket.assigns[:kept_params] || []
    return_to = if kept_params == [], do: path, else: "#{path}?#{URI.encode_query(kept_params)}"

    # A LiveView cannot write the session, so the pick goes through a controller that can.
    {:halt, redirect(socket, to: ~p"/project-selection?#{[project_id: project_id, return_to: return_to]}")}
  end

  defp handle_nav_events(_event, _params, socket) do
    {:cont, socket}
  end
end
