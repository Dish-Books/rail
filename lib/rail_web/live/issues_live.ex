defmodule RailWeb.IssuesLive do
  @moduledoc false
  use RailWeb, :live_view

  import RailWeb.CoreComponents,
    only: [
      archive_issue_modal: 1,
      icon: 1,
      issue_card: 1,
      issue_editor_modal: 1
    ]

  alias Rail.Domain.Enums.IssueState
  alias Rail.Domain.Enums.TaskPriority
  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Projects

  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline_changed")
    end

    socket =
      socket
      |> assign(:page_title, "Issues")
      |> assign(:current_section, :issues)
      |> assign(:current_project_id, nil)
      |> assign(:current_project, nil)
      |> assign(:show_finished, false)
      |> assign(:filter_priority, nil)
      |> assign(:all_issues, [])
      |> assign(:visible_issues, [])
      |> assign(:filtered_issues, [])
      |> assign(:priority_counts, %{})
      |> assign(:tasks_by_issue_id, %{})
      |> assign(:is_syncing, false)
      |> assign(:editing_issue, nil)
      |> assign(:archiving_issue, nil)

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
      |> load_project(project_id)
      |> reload_data()

    {:noreply, socket}
  end

  def render(assigns) do
    ~H"""
    <div id="issues-view" data-qa="issues-view" class="space-y-6">
      <!-- Header row: Title + Subtitle on Left, Sync and New Issue buttons on Right -->
      <div class="flex items-center justify-between gap-4 flex-wrap" id="issues-header">
        <div>
          <h1
            class="text-2xl font-bold tracking-tight text-[var(--color-on-surface)]"
            id="issues-title"
            data-qa="issues_title"
          >
            Issues
          </h1>
          <p
            class="text-xs text-[var(--color-outline)] mt-1"
            id="issues-subtitle"
            data-qa="issues-subtitle"
          >
            {subtitle_for(@current_project)}
          </p>
        </div>

        <div class="flex items-center gap-3">
          <!-- Sync Issues button -->
          <button
            type="button"
            id="sync-issues-button"
            data-qa="sync-issues-button"
            phx-click="sync_issues"
            disabled={@is_syncing}
            title="Pulls issues from Linear"
            class={[
              "inline-flex items-center gap-2 px-3 py-1.5 rounded-lg border border-[var(--color-outline)] text-xs font-semibold text-[var(--color-on-surface)] hover:bg-[var(--color-surface-container)] transition-colors cursor-pointer",
              @is_syncing && "opacity-50 cursor-not-allowed"
            ]}
          >
            <.icon :if={not @is_syncing} name="sync" class="h-4 w-4" />
            <span
              :if={@is_syncing}
              class="inline-block animate-spin h-3.5 w-3.5 border-2 border-current border-t-transparent rounded-full mr-1"
            ></span>
            <span>{if @is_syncing, do: "Syncing...", else: "Sync Issues"}</span>
          </button>

          <!-- New Issue button -->
          <button
            type="button"
            id="new-issue-button"
            data-qa="capture-issue-button new-issue-button"
            phx-click="open_new_issue"
            class="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg bg-[var(--color-primary)] text-[var(--color-on-primary)] text-xs font-semibold hover:opacity-90 transition-opacity cursor-pointer shadow-xs"
          >
            <.icon name="add_circle" class="h-4 w-4" />
            <span>New Issue</span>
          </button>
        </div>
      </div>

      <!-- Filter chips bar: All, Priority chips, Show finished toggle -->
      <div class="flex items-center gap-2 flex-wrap py-1" id="issues-filters-bar">
        <!-- All Chip -->
        <button
          type="button"
          id="filter-priority-all"
          data-qa="issues-filter-all"
          phx-click="filter_priority"
          phx-value-priority="all"
          class={[
            "px-3 py-1 rounded-full text-xs font-semibold transition-colors cursor-pointer",
            if(is_nil(@filter_priority),
              do: "bg-[var(--color-primary)] text-[var(--color-on-primary)]",
              else:
                "bg-[var(--color-surface-container-highest)] text-[var(--color-on-surface)] hover:bg-[var(--color-surface-container-high)]"
            )
          ]}
        >
          All ({length(@visible_issues)})
        </button>

        <!-- Priority Chips -->
        <%= for p <- TaskPriority.values() do %>
          <button
            type="button"
            id={"filter-priority-#{p}"}
            data-qa={"issues-filter-#{p}"}
            phx-click="filter_priority"
            phx-value-priority={to_string(p)}
            class={[
              "px-3 py-1 rounded-full text-xs font-semibold transition-colors cursor-pointer",
              if(@filter_priority == p,
                do: "bg-[var(--color-primary)] text-[var(--color-on-primary)]",
                else:
                  "bg-[var(--color-surface-container-highest)] text-[var(--color-on-surface)] hover:bg-[var(--color-surface-container-high)]"
              )
            ]}
          >
            {TaskPriority.label(p)} ({Map.get(@priority_counts, p, 0)})
          </button>
        <% end %>

        <div class="h-4 w-px bg-[var(--color-outline-variant)] mx-1"></div>

        <!-- Show finished filter chip -->
        <button
          type="button"
          id="issues-show-finished"
          data-qa="issues-show-finished"
          phx-click="toggle_show_finished"
          class={[
            "px-3 py-1 rounded-full text-xs font-semibold transition-colors cursor-pointer flex items-center gap-1.5",
            if(@show_finished,
              do:
                "bg-[var(--color-primary-container)] text-[var(--color-on-primary-container)] border border-[var(--color-primary)]",
              else:
                "bg-[var(--color-surface-container-highest)] text-[var(--color-on-surface)] hover:bg-[var(--color-surface-container-high)]"
            )
          ]}
        >
          <.icon :if={@show_finished} name="check" class="h-3.5 w-3.5" />
          <span>Show finished</span>
        </button>

        <!-- Search input -->
        <div class="relative ml-auto">
          <input
            type="text"
            id="issues-search"
            data-qa="issues-search"
            placeholder="Search issues..."
            class="px-3 py-1 text-xs rounded-lg border border-[var(--color-outline-variant)] bg-[var(--color-surface)] text-[var(--color-on-surface)] placeholder-[var(--color-outline)] focus:outline-none focus:ring-1 focus:ring-[var(--color-primary)]"
          />
        </div>
      </div>

      <!-- Issues List or Empty State -->
      <div id="issues-content">
        <!-- Empty State -->
        <div
          :if={@filtered_issues == []}
          id="issues-empty-state"
          data-qa="issues-empty-state"
          class="m3-card p-12 flex flex-col items-center justify-center text-center space-y-4"
        >
          <.icon name="lightbulb" class="h-14 w-14 text-[var(--color-outline)] opacity-70" />
          <h2
            class="text-base font-semibold text-[var(--color-outline)]"
            data-qa="empty-state-title"
          >
            No issues in this view
          </h2>
          <button
            type="button"
            id="add-first-issue-button"
            data-qa="empty-add-issue-button"
            phx-click="open_new_issue"
            class="px-4 py-2 rounded-lg bg-[var(--color-surface-container-highest)] hover:bg-[var(--color-surface-container-high)] text-xs font-semibold text-[var(--color-on-surface)] transition-colors cursor-pointer"
          >
            Add first issue
          </button>
        </div>

        <!-- Issues Cards List -->
        <div
          :if={@filtered_issues != []}
          id="issues-list"
          data-qa="issues-table issues-list"
          class="space-y-4"
        >
          <div :for={issue <- @filtered_issues}>
            <.issue_card
              issue={issue}
              task={Map.get(@tasks_by_issue_id, issue.id)}
            />
          </div>
        </div>
      </div>

      <!-- Issue Editor Modal -->
      <.issue_editor_modal
        issue={@editing_issue}
        visible={@editing_issue != nil}
      />

      <!-- Archive Confirmation Modal -->
      <.archive_issue_modal
        issue={@archiving_issue}
        visible={@archiving_issue != nil}
      />
    </div>
    """
  end

  def handle_event("filter_priority", %{"priority" => priority_str}, socket) do
    new_filter =
      case priority_str do
        "all" ->
          nil

        str ->
          case TaskPriority.cast(str) do
            {:ok, priority} ->
              if socket.assigns.filter_priority == priority, do: nil, else: priority

            :error ->
              nil
          end
      end

    socket =
      socket
      |> assign(:filter_priority, new_filter)
      |> apply_filters()

    {:noreply, socket}
  end

  def handle_event("toggle_show_finished", _params, socket) do
    new_show_finished = not socket.assigns.show_finished

    socket =
      socket
      |> assign(:show_finished, new_show_finished)
      |> reload_data()

    {:noreply, socket}
  end

  def handle_event("sync_issues", _params, socket) do
    scope = socket.assigns[:current_scope]
    project = socket.assigns.current_project

    socket = assign(socket, :is_syncing, true)

    if project do
      Issues.sync_issues(scope, project)
    else
      projects = Projects.list_projects(scope)
      Enum.each(projects, fn p -> Issues.sync_issues(scope, p) end)
    end

    socket =
      socket
      |> assign(:is_syncing, false)
      |> reload_data()

    {:noreply, socket}
  end

  def handle_event("bring_local", %{"issue_id" => issue_id}, socket) do
    scope = socket.assigns[:current_scope]
    user = socket.assigns[:current_user]

    case Issues.get_issue(scope, issue_id) do
      {:ok, issue} ->
        Pipeline.bring_local(scope, issue, user)
        socket = reload_data(socket)
        {:noreply, socket}

      _error ->
        {:noreply, socket}
    end
  end

  def handle_event("open_editor", %{"issue_id" => issue_id}, socket) do
    scope = socket.assigns[:current_scope]

    case Issues.get_issue(scope, issue_id) do
      {:ok, issue} ->
        socket = assign(socket, :editing_issue, issue)
        {:noreply, socket}

      _error ->
        {:noreply, socket}
    end
  end

  def handle_event("close_editor", _params, socket) do
    socket = assign(socket, :editing_issue, nil)
    {:noreply, socket}
  end

  def handle_event("save_issue", %{"issue_id" => issue_id, "title" => title} = params, socket) do
    trimmed_title = String.trim(title)

    if trimmed_title == "" do
      {:noreply, socket}
    else
      scope = socket.assigns[:current_scope]

      case Issues.get_issue(scope, issue_id) do
        {:ok, issue} ->
          attrs = %{
            title: trimmed_title,
            description: Map.get(params, "description"),
            priority: Map.get(params, "priority"),
            state: Map.get(params, "state")
          }

          Issues.update_issue(scope, issue, attrs)

          socket =
            socket
            |> assign(:editing_issue, nil)
            |> reload_data()

          {:noreply, socket}

        _error ->
          {:noreply, socket}
      end
    end
  end

  def handle_event("editor_change", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("open_archive", %{"issue_id" => issue_id}, socket) do
    scope = socket.assigns[:current_scope]

    case Issues.get_issue(scope, issue_id) do
      {:ok, issue} ->
        socket = assign(socket, :archiving_issue, issue)
        {:noreply, socket}

      _error ->
        {:noreply, socket}
    end
  end

  def handle_event("close_archive", _params, socket) do
    socket = assign(socket, :archiving_issue, nil)
    {:noreply, socket}
  end

  def handle_event("confirm_archive", %{"issue_id" => issue_id}, socket) do
    scope = socket.assigns[:current_scope]

    case Issues.get_issue(scope, issue_id) do
      {:ok, issue} ->
        Issues.archive_issue(scope, issue)

        socket =
          socket
          |> assign(:archiving_issue, nil)
          |> assign(:editing_issue, nil)
          |> reload_data()

        {:noreply, socket}

      _error ->
        {:noreply, socket}
    end
  end

  def handle_info(:pipeline_changed, socket) do
    socket = reload_data(socket)
    {:noreply, socket}
  end

  def handle_info(%{event: "pipeline_changed"}, socket) do
    socket = reload_data(socket)
    {:noreply, socket}
  end

  def handle_info({:live_sync, _data}, socket) do
    socket = reload_data(socket)
    {:noreply, socket}
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  def subtitle_for(nil), do: "Linear issues across all projects"

  def subtitle_for(%{linear_team_key: key, name: name}) when is_binary(key) and key != "" do
    "Linear issues in #{key} (#{name})"
  end

  def subtitle_for(%{name: name}) when is_binary(name) and name != "" do
    "Linear issues for #{name}"
  end

  def subtitle_for(_other), do: "No target repository set • Issues live in Linear; set one in Settings"

  # --- Private Helpers ---

  defp load_project(socket, nil) do
    assign(socket, :current_project, nil)
  end

  defp load_project(socket, project_id) when is_binary(project_id) do
    scope = socket.assigns[:current_scope]

    case Projects.get_project(scope, project_id) do
      {:ok, project} ->
        assign(socket, :current_project, project)

      _error ->
        assign(socket, :current_project, nil)
    end
  end

  defp reload_data(socket) do
    scope = socket.assigns[:current_scope]
    project_id = socket.assigns.current_project_id
    show_finished = socket.assigns.show_finished

    opts = [preload: [:project], show_finished: show_finished]

    all_issues =
      if project_id do
        Issues.list_issues(scope, Keyword.put(opts, :project_id, project_id))
      else
        Issues.list_issues(scope, opts)
      end

    tasks = Pipeline.list_tasks(scope, project_id)
    tasks_by_issue_id = Map.new(tasks, fn task -> {task.issue_id, task} end)

    visible_issues =
      if show_finished do
        all_issues
      else
        Enum.reject(all_issues, &IssueState.finished?(&1.state))
      end

    priority_counts =
      Enum.reduce(visible_issues, %{}, fn issue, acc ->
        Map.update(acc, issue.priority, 1, &(&1 + 1))
      end)

    socket
    |> assign(:all_issues, all_issues)
    |> assign(:visible_issues, visible_issues)
    |> assign(:priority_counts, priority_counts)
    |> assign(:tasks_by_issue_id, tasks_by_issue_id)
    |> apply_filters()
  end

  defp apply_filters(socket) do
    visible_issues = socket.assigns.visible_issues
    filter_priority = socket.assigns.filter_priority

    filtered_issues =
      if filter_priority do
        Enum.filter(visible_issues, fn issue -> issue.priority == filter_priority end)
      else
        visible_issues
      end

    assign(socket, :filtered_issues, filtered_issues)
  end
end
