defmodule RailWeb.IssuesLive do
  @moduledoc false
  use RailWeb, :live_view

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects
  alias RailWeb.Components.CaptureIssueModal

  @page_size 50

  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Rail.PubSub, "issues")

    socket =
      socket
      |> assign(:page_title, "Issues")
      |> assign(:current_section, :issues)
      |> assign(:current_project, nil)
      |> assign(:syncing_project_ids, MapSet.new())
      |> assign(:is_syncing, false)

    {:ok, socket}
  end

  # The search, filters and page are in the URL, so they can be linked to and
  # survive a reload; the project is the switcher's.
  def handle_params(params, _uri, socket) do
    socket =
      socket
      |> assign(:page_title, "Issues")
      |> assign(:current_section, :issues)
      |> assign(:search, params["q"] || "")
      |> assign(:filter_priority, Enum.find(Issue.priorities(), &(to_string(&1) == params["priority"])))
      |> assign(:show_finished, params["finished"] == "true")
      |> assign(:mine, params["mine"] == "true")
      |> assign(:page, page_number(params["page"]))
      |> load_project(socket.assigns.current_project_id)
      |> reload_data()

    {:noreply, socket}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_section={@current_section}
      current_scope={@current_scope}
      is_rail_extended={@is_rail_extended}
      attention_count={@attention_count}
      current_project_id={@current_project_id}
      projects={@projects}
      theme={@theme}
      show_project_switcher={@show_project_switcher}
    >
      <div id="issues-view" data-qa="issues-view" class="space-y-6">
        <!-- Header row: Title + Subtitle on Left, Sync and New Issue buttons on Right -->
        <div class="flex items-center justify-between gap-4 flex-wrap" id="issues-header">
          <div>
            <h1
              class="text-2xl font-bold tracking-tight text-slate-900 dark:text-slate-100"
              id="issues-title"
              data-qa="issues_title"
            >
              Issues
            </h1>
            <p
              class="text-xs text-slate-500 dark:text-slate-400 mt-1"
              id="issues-subtitle"
              data-qa="issues-subtitle"
            >
              {project_subtitle(@current_project)}
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
                "inline-flex items-center gap-2 px-3 py-1.5 rounded-lg border border-slate-500 dark:border-slate-400 text-xs font-semibold text-slate-900 dark:text-slate-100 hover:bg-slate-50 dark:hover:bg-slate-800 transition-colors cursor-pointer",
                @is_syncing && "opacity-50 cursor-not-allowed"
              ]}
            >
              <.icon :if={not @is_syncing} name="pi-arrows-clockwise" class="h-4 w-4" />
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
              phx-click={CaptureIssueModal.open()}
              class="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg bg-blue-600 dark:bg-blue-500 text-white text-xs font-semibold hover:opacity-90 transition-opacity cursor-pointer shadow-xs"
            >
              <.icon name="pi-plus-circle-fill" class="h-4 w-4" />
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
                do: "bg-blue-600 dark:bg-blue-500 text-white",
                else:
                  "bg-slate-200 dark:bg-slate-600 text-slate-900 dark:text-slate-100 hover:bg-slate-100 dark:hover:bg-slate-700"
              )
            ]}
          >
            All ({@all_count})
          </button>

          <!-- Priority Chips -->
          <%= for p <- Issue.priorities() do %>
            <button
              type="button"
              id={"filter-priority-#{p}"}
              data-qa={"issues-filter-#{p}"}
              phx-click="filter_priority"
              phx-value-priority={to_string(p)}
              class={[
                "px-3 py-1 rounded-full text-xs font-semibold transition-colors cursor-pointer",
                if(@filter_priority == p,
                  do: "bg-blue-600 dark:bg-blue-500 text-white",
                  else:
                    "bg-slate-200 dark:bg-slate-600 text-slate-900 dark:text-slate-100 hover:bg-slate-100 dark:hover:bg-slate-700"
                )
              ]}
            >
              {Issue.priority_label(p)} ({Map.get(@priority_counts, p, 0)})
            </button>
          <% end %>

          <div class="h-4 w-px bg-slate-300 dark:bg-slate-600 mx-1"></div>

          <button
            type="button"
            id="issues-mine"
            data-qa="issues-mine"
            phx-click="toggle_mine"
            class={[
              "px-3 py-1 rounded-full text-xs font-semibold transition-colors cursor-pointer flex items-center gap-1.5",
              if(@mine,
                do:
                  "bg-blue-100 dark:bg-blue-900 text-blue-800 dark:text-blue-200 border border-blue-600 dark:border-blue-500",
                else:
                  "bg-slate-200 dark:bg-slate-600 text-slate-900 dark:text-slate-100 hover:bg-slate-100 dark:hover:bg-slate-700"
              )
            ]}
          >
            <.icon :if={@mine} name="pi-check" class="h-3.5 w-3.5" />
            <span>My issues</span>
          </button>

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
                  "bg-blue-100 dark:bg-blue-900 text-blue-800 dark:text-blue-200 border border-blue-600 dark:border-blue-500",
                else:
                  "bg-slate-200 dark:bg-slate-600 text-slate-900 dark:text-slate-100 hover:bg-slate-100 dark:hover:bg-slate-700"
              )
            ]}
          >
            <.icon :if={@show_finished} name="pi-check" class="h-3.5 w-3.5" />
            <span>Show finished</span>
          </button>

          <!-- Search input -->
          <form
            id="issues-search-form"
            class="relative ml-auto"
            phx-change="search"
            phx-submit="search"
          >
            <input
              type="search"
              id="issues-search"
              name="q"
              value={@search}
              phx-debounce="300"
              autocomplete="off"
              data-qa="issues-search"
              placeholder="Search issues..."
              class="px-3 py-1 text-xs rounded-lg border border-slate-300 dark:border-slate-600 bg-white dark:bg-slate-900 text-slate-900 dark:text-slate-100 placeholder-slate-500 dark:placeholder-slate-400 focus:outline-none focus:ring-1 focus:ring-blue-600 dark:focus:ring-blue-500"
            />
          </form>
        </div>

        <!-- Issues List or Empty State -->
        <div id="issues-content">
          <!-- Empty State -->
          <div
            :if={@issues == []}
            id="issues-empty-state"
            data-qa="issues-empty-state"
            class="rounded-xl border border-slate-200 bg-slate-50 dark:border-slate-700 dark:bg-slate-800 p-12 flex flex-col items-center justify-center text-center space-y-4"
          >
            <.icon
              name="pi-lightbulb-fill"
              class="h-14 w-14 text-slate-500 dark:text-slate-400 opacity-70"
            />
            <h2
              class="text-base font-semibold text-slate-500 dark:text-slate-400"
              data-qa="empty-state-title"
            >
              {if String.trim(@search) == "", do: "No issues in this view", else: "No issues match"}
            </h2>
            <button
              type="button"
              id="add-first-issue-button"
              data-qa="empty-add-issue-button"
              phx-click={CaptureIssueModal.open()}
              class="px-4 py-2 rounded-lg bg-slate-200 dark:bg-slate-600 hover:bg-slate-100 dark:hover:bg-slate-700 text-xs font-semibold text-slate-900 dark:text-slate-100 transition-colors cursor-pointer"
            >
              Add first issue
            </button>
          </div>

          <!-- Issues Cards List -->
          <div
            :if={@issues != []}
            id="issues-list"
            data-qa="issues-table issues-list"
            class="rounded-xl border border-slate-200 dark:border-slate-700 divide-y divide-slate-200 dark:divide-slate-800 overflow-hidden"
          >
            <.issue_card
              :for={issue <- @issues}
              issue={issue}
              task={issue.task}
              run={stage_run(issue.task)}
            />
          </div>

          <div
            :if={@total > 0}
            id="issues-pagination"
            data-qa="issues-pagination"
            class="flex items-center justify-between gap-4 pt-4 text-xs text-slate-500 dark:text-slate-400"
          >
            <span id="issues-page-range">
              Showing {@page_first}–{@page_last} of {@total}
            </span>
            <div class="flex items-center gap-2">
              <.link
                :if={@prev_path}
                id="issues-page-prev"
                patch={@prev_path}
                class="px-3 py-1 rounded-lg border border-slate-300 dark:border-slate-600 font-semibold text-slate-900 dark:text-slate-100 hover:bg-slate-100 dark:hover:bg-slate-700"
              >
                Previous
              </.link>
              <span
                :if={!@prev_path}
                class="px-3 py-1 rounded-lg border border-slate-200 dark:border-slate-700 font-semibold opacity-50"
              >
                Previous
              </span>
              <.link
                :if={@next_path}
                id="issues-page-next"
                patch={@next_path}
                class="px-3 py-1 rounded-lg border border-slate-300 dark:border-slate-600 font-semibold text-slate-900 dark:text-slate-100 hover:bg-slate-100 dark:hover:bg-slate-700"
              >
                Next
              </.link>
              <span
                :if={!@next_path}
                class="px-3 py-1 rounded-lg border border-slate-200 dark:border-slate-700 font-semibold opacity-50"
              >
                Next
              </span>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  def handle_event("search", %{"q" => search}, socket) do
    {:noreply, push_patch(socket, to: issues_path(socket.assigns, q: search, page: 1))}
  end

  def handle_event("filter_priority", %{"priority" => priority}, socket) do
    {:noreply, push_patch(socket, to: issues_path(socket.assigns, priority: priority, page: 1))}
  end

  def handle_event("toggle_mine", _params, socket) do
    {:noreply, push_patch(socket, to: issues_path(socket.assigns, mine: not socket.assigns.mine, page: 1))}
  end

  def handle_event("toggle_show_finished", _params, socket) do
    path = issues_path(socket.assigns, finished: not socket.assigns.show_finished, page: 1)
    {:noreply, push_patch(socket, to: path)}
  end

  # The pull runs in the background a page at a time; the button stays busy
  # until every project it started has said it is done.
  def handle_event("sync_issues", _params, socket) do
    projects =
      if project = socket.assigns.current_project,
        do: [project],
        else: Projects.list_projects()

    Enum.each(projects, &Issues.sync_issues/1)

    ids = MapSet.union(socket.assigns.syncing_project_ids, MapSet.new(projects, & &1.id))

    {:noreply, assign_syncing(socket, ids)}
  end

  def handle_info({:issues_synced, project_id}, socket) do
    ids = MapSet.delete(socket.assigns.syncing_project_ids, project_id)

    socket = socket |> assign_syncing(ids) |> reload_data()
    {:noreply, socket}
  end

  # Newest first, so a created issue lands at the top of the first page.
  def handle_info({:issue_created, _issue_id}, socket), do: {:noreply, reload_data(socket)}

  def handle_info({:issue_comments_changed, _issue_id}, socket), do: {:noreply, socket}

  # Where a task got to is what the run for the stage it sits at says, picked out
  # of the runs already loaded rather than queried per row.
  defp stage_run(%{runs: runs, stage: stage}) when is_list(runs) do
    Enum.find(runs, &(&1.role != nil and &1.role.stage == stage))
  end

  defp stage_run(nil), do: nil

  defp project_subtitle(nil), do: "Linear issues across all projects"

  defp project_subtitle(%{linear_team_key: key, name: name}), do: "Linear issues in #{key} (#{name})"

  # --- Private Helpers ---

  defp load_project(socket, nil) do
    assign(socket, :current_project, nil)
  end

  defp load_project(socket, project_id) when is_binary(project_id) do
    case Projects.get_project(project_id) do
      {:ok, project} ->
        assign(socket, :current_project, project)

      _error ->
        assign(socket, :current_project, nil)
    end
  end

  defp reload_data(socket) do
    assigns = socket.assigns
    offset = (assigns.page - 1) * @page_size

    %{issues: issues, total: total, priority_counts: priority_counts} =
      Issues.list_issues(
        project_id: assigns.current_project_id,
        owner_user_id: if(assigns.mine, do: assigns.current_scope.user.id),
        show_finished: assigns.show_finished,
        search: assigns.search,
        priority: assigns.filter_priority,
        limit: @page_size,
        offset: offset,
        preload: [:project, :owner_user, task: [runs: :role]]
      )

    last_page = max(div(total + @page_size - 1, @page_size), 1)

    # A linked page past the end (fewer matches since) shows the last one instead.
    if assigns.page > last_page do
      socket |> assign(:page, last_page) |> reload_data()
    else
      assign_page(socket, issues, total, priority_counts, offset)
    end
  end

  defp assign_page(socket, issues, total, priority_counts, offset) do
    assigns = socket.assigns

    socket
    |> assign(:issues, issues)
    |> assign(:total, total)
    |> assign(:priority_counts, priority_counts)
    |> assign(:all_count, priority_counts |> Map.values() |> Enum.sum())
    |> assign(:page_first, min(offset + 1, total))
    |> assign(:page_last, min(offset + @page_size, total))
    |> assign(:prev_path, if(assigns.page > 1, do: issues_path(assigns, page: assigns.page - 1)))
    |> assign(:next_path, if(offset + @page_size < total, do: issues_path(assigns, page: assigns.page + 1)))
  end

  # Defaults stay out of the URL, so the plain list is still just /issues.
  defp issues_path(assigns, changes) do
    params =
      [
        q: assigns.search,
        priority: assigns.filter_priority,
        mine: assigns.mine,
        finished: assigns.show_finished,
        page: assigns.page
      ]
      |> Keyword.merge(changes)
      |> Enum.reject(fn {key, value} -> value in [nil, "", false, "all"] or {key, value} == {:page, 1} end)

    case params do
      [] -> ~p"/issues"
      params -> ~p"/issues?#{params}"
    end
  end

  defp assign_syncing(socket, ids) do
    socket
    |> assign(:syncing_project_ids, ids)
    |> assign(:is_syncing, MapSet.size(ids) > 0)
  end

  defp page_number(value) when is_binary(value) do
    case Integer.parse(value) do
      {page, ""} when page > 0 -> page
      _invalid -> 1
    end
  end

  defp page_number(_missing), do: 1
end
