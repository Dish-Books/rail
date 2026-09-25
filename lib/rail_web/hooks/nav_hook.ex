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

  # What needs a human is counted in tasks, the same as the overview lists them:
  # a task waits only if the latest run at its stage does, not one it has retried.
  defp count_attention(projects) do
    projects
    |> Enum.flat_map(fn project ->
      Pipeline.list_runs(project_id: project.id, preload: [:role, :questions, task: :issue])
    end)
    |> Enum.filter(&(&1.role.stage == &1.task.stage))
    |> Enum.group_by(& &1.task_id)
    |> Enum.count(fn {_task_id, stage_runs} ->
      stage_runs |> Enum.max_by(&(&1.started_at || &1.inserted_at), DateTime) |> Run.needs_attention?()
    end)
  end
end
