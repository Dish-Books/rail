defmodule RailWeb.Hooks.NavHook do
  @moduledoc false
  use RailWeb, :live_view

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Projects

  def on_mount(:default, _params, session, socket) do
    projects = Projects.list_projects()

    attention_count = count_attention(projects)

    socket =
      socket
      |> assign(:is_rail_extended, true)
      |> assign(:theme, "dark")
      |> assign(:show_project_switcher, false)
      |> assign(:projects, projects)
      |> assign(:attention_count, attention_count)
      |> assign(:current_project_id, session["selected_project_id"])
      |> assign(:current_section, :overview)
      |> attach_hook(:nav_handle_params, :handle_params, &handle_nav_params/3)
      |> attach_hook(:nav_handle_events, :handle_event, &handle_nav_events/3)

    {:cont, socket}
  end

  defp handle_nav_params(_params, uri, socket) do
    {:cont, assign(socket, :current_path, URI.parse(uri).path)}
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

    # A LiveView cannot write the session, so the pick goes through a controller that can.
    {:halt, redirect(socket, to: ~p"/project-selection?#{[project_id: project_id, return_to: path]}")}
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
