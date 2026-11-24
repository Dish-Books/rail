defmodule RailWeb.Hooks.NavHook do
  @moduledoc false
  use RailWeb, :live_view

  alias Rail.Pipeline
  alias Rail.Projects
  alias Rail.Scope
  alias Rail.Support
  alias Rail.Tools
  alias Rail.Triage
  alias Rail.Users
  alias RailWeb.Components.TodosPanel

  # An import broadcasts once per conversation, so the Support badge recounts at most once a second.
  @support_recount_after 1_000

  def on_mount(:default, _params, session, socket) do
    scope = socket.assigns.current_scope
    projects = Projects.list_projects(scope)
    # A lost project stays in the session, so it comes back selected if access is granted again.
    current_project_id = Enum.find_value(projects, &(&1.id == session["selected_project_id"] && &1.id))

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Rail.PubSub, "todos:#{scope.user.id}")

      if support_listener?(socket) and Users.can?(scope, :support, :view),
        do: Phoenix.PubSub.subscribe(Rail.PubSub, "support")

      params = get_connect_params(socket)

      # Handled once this mount has rendered, when the panel exists; a reconnect joins again and sends it again.
      send_update(TodosPanel,
        id: TodosPanel.id(),
        browser: %{open: params["todos_open"] == true, time_zone: params["time_zone"] || "Etc/UTC"}
      )
    end

    socket =
      socket
      |> assign(:theme, "dark")
      |> assign(:show_project_switcher, false)
      |> assign(:projects, projects)
      # The badge is what waits on this user, as the Overview's Waiting on you counts it.
      |> assign(
        :attention_count,
        if(Users.can?(scope, :overview, :view),
          do: Pipeline.count_attention(project_id: Scope.project_ids(scope), owner_user_id: scope.user.id),
          else: 0
        )
      )
      # A role without the tab never sees its badge, so its count is not loaded.
      |> assign(
        :triage_count,
        if(Users.can?(scope, :triage, :view),
          do: Triage.count_triage_threads(project_id: Scope.project_ids(scope)).waiting,
          else: 0
        )
      )
      |> assign(:support_count, count_support(scope))
      |> assign(:support_recount_scheduled, false)
      |> assign(:current_project_id, current_project_id)
      # What a page lists: the selected project, or else every project the user can see.
      |> assign(:project_filter, current_project_id || Scope.project_ids(scope))
      |> assign(:current_section, :overview)
      |> assign(:lost_backends, Enum.filter(Tools.list_backends(), & &1.session_lost_at))
      |> attach_hook(:nav_handle_params, :handle_params, &handle_nav_params/3)
      |> attach_hook(:nav_handle_events, :handle_event, &handle_nav_events/3)
      |> attach_hook(:nav_todos, :handle_info, &handle_todos_info/2)
      |> attach_support_hook()

    {:cont, socket}
  end

  # The badge is what the Support queue's Waiting filter lists, across every project the user can see. A role without
  # the tab never sees it, so it is not counted.
  def count_support(scope) do
    if Users.can?(scope, :support, :view),
      do: Support.count_support_conversations(project_id: Scope.project_ids(scope)).waiting,
      else: 0
  end

  defp handle_nav_params(params, uri, socket) do
    socket =
      socket
      |> assign(:current_path, URI.parse(uri).path)
      # The Overview's everyone's-work view survives a change of project.
      |> assign(:kept_params, if(params["everyone"] == "true", do: [everyone: true], else: []))

    {:cont, socket}
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

  # A live component cannot subscribe, so the page hands each change on to the panel.
  defp handle_todos_info({:todos_changed, _user_id}, socket) do
    send_update(TodosPanel, id: TodosPanel.id(), refresh: true)
    {:halt, socket}
  end

  defp handle_todos_info(_message, socket), do: {:cont, socket}

  # The Support page listens and recounts on each load itself: a second subscription would deliver twice, and this
  # hook would take its messages.
  defp support_listener?(socket), do: socket.view != RailWeb.SupportLive

  defp attach_support_hook(socket) do
    if support_listener?(socket),
      do: attach_hook(socket, :nav_support, :handle_info, &handle_support_info/2),
      else: socket
  end

  defp handle_support_info({:support_changed, _conversation_id}, %{assigns: %{support_recount_scheduled: true}} = socket),
    do: {:halt, socket}

  defp handle_support_info({:support_changed, _conversation_id}, socket) do
    Process.send_after(self(), :nav_support_recount, @support_recount_after)
    {:halt, assign(socket, :support_recount_scheduled, true)}
  end

  defp handle_support_info(:nav_support_recount, socket) do
    socket =
      socket
      |> assign(:support_recount_scheduled, false)
      |> assign(:support_count, count_support(socket.assigns.current_scope))

    {:halt, socket}
  end

  defp handle_support_info(_message, socket), do: {:cont, socket}
end
