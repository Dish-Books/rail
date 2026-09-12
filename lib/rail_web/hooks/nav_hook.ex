defmodule RailWeb.Hooks.NavHook do
  @moduledoc false
  use RailWeb, :live_view

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
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
      |> assign(:show_new_issue_modal, false)
      |> assign(:capture_ask, "")
      |> assign(:capture_project_id, nil)
      |> assign(:capture_priority, :medium)
      |> assign(:capture_error, nil)
      |> assign(:capture_submitting, false)
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

    if socket.assigns[:current_scope] do
      Users.set_project_filter(socket.assigns.current_scope, project_id)
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

  defp handle_nav_events("open_new_issue", _params, socket) do
    default_project_id =
      default_capture_project_id(socket.assigns.projects, socket.assigns.current_project_id)

    socket =
      socket
      |> assign(:show_new_issue_modal, true)
      |> assign(:capture_ask, "")
      |> assign(:capture_project_id, default_project_id)
      |> assign(:capture_priority, :medium)
      |> assign(:capture_error, nil)
      |> assign(:capture_submitting, false)

    {:halt, socket}
  end

  defp handle_nav_events("close_new_issue", _params, socket) do
    socket =
      socket
      |> assign(:show_new_issue_modal, false)
      |> assign(:capture_ask, "")
      |> assign(:capture_error, nil)
      |> assign(:capture_submitting, false)

    {:halt, socket}
  end

  defp handle_nav_events("capture_form_change", params, socket) do
    {ask, project_id, priority} = extract_capture_params(params)

    socket =
      socket
      |> assign(:capture_ask, ask)
      |> assign(:capture_project_id, project_id)
      |> assign(:capture_priority, priority)

    {:halt, socket}
  end

  defp handle_nav_events("capture_form_submit", params, socket) do
    {ask, project_id, priority} = extract_capture_params(params)

    if String.trim(ask) == "" do
      {:halt, socket}
    else
      scope = socket.assigns.current_scope

      project =
        Enum.find(socket.assigns.projects, &(&1.id == project_id)) ||
          fetch_project(scope, project_id)

      if is_nil(project) do
        socket =
          socket
          |> assign(:capture_submitting, false)
          |> assign(:capture_error, "Project not found")

        {:halt, socket}
      else
        socket = assign(socket, :capture_submitting, true)

        case Issues.capture_issue(scope, project, ask, priority: priority) do
          {:ok, issue} ->
            # Other views still learn about the issue over PubSub; this one owns
            # the capture, so it refreshes its own counts directly.
            Pipeline.broadcast_pipeline_changed(%{event: :issue_captured, issue_id: issue.id})

            socket =
              socket
              |> refresh_nav_state()
              |> assign(:show_new_issue_modal, false)
              |> assign(:capture_ask, "")
              |> assign(:capture_project_id, nil)
              |> assign(:capture_priority, :medium)
              |> assign(:capture_error, nil)
              |> assign(:capture_submitting, false)

            {:halt, socket}

          {:error, reason} ->
            socket =
              socket
              |> assign(:capture_ask, ask)
              |> assign(:capture_project_id, project_id)
              |> assign(:capture_priority, priority)
              |> assign(:capture_submitting, false)
              |> assign(:capture_error, format_capture_error(reason))

            {:halt, socket}
        end
      end
    end
  end

  defp handle_nav_events(_event, _params, socket) do
    {:cont, socket}
  end

  defp refresh_nav_state(socket) do
    scope = socket.assigns.current_scope
    projects = Projects.list_projects(scope)
    attention_count = count_attention(projects)

    socket
    |> assign(:projects, projects)
    |> assign(:attention_count, attention_count)
  end

  defp count_attention(projects) do
    tasks =
      Enum.flat_map(projects, fn project ->
        Pipeline.list_tasks(project.id)
      end)

    Enum.count(tasks, &Rail.Domain.OverviewQueue.needs_attention?/1)
  end

  defp default_capture_project_id(projects, current_project_id) do
    active_projects = Enum.filter(projects, & &1.active)

    cond do
      is_binary(current_project_id) and
          Enum.any?(active_projects, &(&1.id == current_project_id)) ->
        current_project_id

      active_projects != [] ->
        hd(active_projects).id

      true ->
        nil
    end
  end

  defp extract_capture_params(params) do
    params = params["capture"] || params["issue"] || params

    ask = Map.get(params, "ask", "")
    project_id = Map.get(params, "project_id")
    raw_priority = Map.get(params, "priority", "medium")

    priority =
      case Issue.cast_priority(raw_priority) do
        {:ok, p} -> p
        :error -> :medium
      end

    {ask, project_id, priority}
  end

  defp fetch_project(_scope, id) when id in [nil, ""], do: nil

  defp fetch_project(scope, project_id) do
    case Projects.get_project(scope, project_id) do
      {:ok, project} -> project
      _other -> nil
    end
  end

  defp format_capture_error(reason) when is_binary(reason), do: reason
  defp format_capture_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_capture_error(reason), do: inspect(reason)
end
