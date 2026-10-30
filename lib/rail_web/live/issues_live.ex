defmodule RailWeb.IssuesLive do
  @moduledoc false
  use RailWeb, :live_view

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Users
  alias Rail.Users.Schemas.User
  alias RailWeb.Components.CaptureIssueModal

  @page_size 50
  # The URL parameters a person's Issues page reopens on; search, the page and which cycle is open are not among them.
  @remembered ["priority", "mine", "finished", "cycle", "owner"]
  @preload [
    :project,
    :owner_user,
    :workflow,
    :children,
    parent: [:project, :owner_user, :workflow, :children],
    task: [runs: :role, parent_task: [children: :issue]]
  ]

  def mount(_params, _session, socket) do
    # Workflows too, since a row names the workflow that opened it.
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Rail.PubSub, "issues")
      Phoenix.PubSub.subscribe(Rail.PubSub, "workflows")
    end

    # The navigation only selects a project it lists, so the selection is always one of these.
    project = Enum.find(socket.assigns.projects, &(&1.id == socket.assigns.current_project_id))
    cycle_projects = if project, do: [project], else: Enum.filter(socket.assigns.projects, & &1.active)
    %User{issues_filters: saved_filters} = socket.assigns.current_scope.user

    socket =
      socket
      |> assign(:page_title, "Issues")
      |> assign(:current_section, :issues)
      |> assign(:current_project, project)
      |> assign(:syncing_project_ids, MapSet.new())
      |> assign(:is_syncing, false)
      |> assign(:saved_filters, saved_filters)
      |> assign(:restore_filters, true)
      |> assign(:blockers, %{})
      |> assign(:blockers_for, [])
      |> load_cycles(cycle_projects)

    {:ok, socket}
  end

  # The search, filters and page are in the URL, so they can be linked to and
  # survive a reload; the project is the switcher's.
  def handle_params(params, _uri, socket) do
    saved = socket.assigns.saved_filters
    restore? = socket.assigns.restore_filters
    socket = assign(socket, :restore_filters, false)

    # Only the first URL after mount opens on the saved filters, replaced so Back still undoes a filter.
    if restore? and saved != %{} and Map.take(params, @remembered) == %{} do
      to = saved |> Map.merge(Map.take(params, ["q", "page"])) |> remembered_path()
      {:noreply, push_patch(socket, to: to, replace: true)}
    else
      mine = params["mine"] == "true"

      socket =
        socket
        |> assign(:page_title, "Issues")
        |> assign(:current_section, :issues)
        |> assign(:search, params["q"] || "")
        |> assign(:filter_priority, Enum.find(Issue.priorities(), &(to_string(&1) == params["priority"])))
        |> assign(:show_finished, params["finished"] == "true")
        |> assign(:mine, mine)
        |> assign(:cycle_param, params["cycle"])
        |> assign(:cycle_offset, cycle_offset(params["offset"]))
        # A link naming both keeps My issues.
        |> assign(:owner_param, if(mine, do: nil, else: params["owner"]))
        |> assign(:page, page_number(params["page"]))
        |> reload_data()

      {:noreply, socket}
    end
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_section={@current_section}
      current_scope={@current_scope}
      attention_count={@attention_count}
      triage_count={@triage_count}
      current_project_id={@current_project_id}
      projects={@projects}
      theme={@theme}
      show_project_switcher={@show_project_switcher}
      lost_backends={@lost_backends}
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
              title="Pulls issues from the tracker"
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
            :if={@show_cycle_chip and not @cycle_on}
            type="button"
            id="cycle-toggle"
            data-qa="issues-cycle-toggle"
            aria-pressed="false"
            phx-click="toggle_cycle"
            class="px-3 py-1 rounded-full text-xs font-semibold transition-colors cursor-pointer bg-slate-200 dark:bg-slate-600 text-slate-900 dark:text-slate-100 hover:bg-slate-100 dark:hover:bg-slate-700 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500"
          >
            Current cycle
          </button>

          <div
            :if={@show_cycle_chip and @cycle_on}
            id="cycle-filter"
            class="inline-flex items-center gap-0.5 pl-1 pr-0.5 h-[26px] rounded-full text-xs font-semibold bg-blue-100 dark:bg-blue-900 text-blue-800 dark:text-blue-200 border border-blue-600 dark:border-blue-500"
          >
            <button
              type="button"
              id="cycle-toggle"
              data-qa="issues-cycle-toggle"
              aria-pressed="true"
              phx-click="toggle_cycle"
              title="Back to all issues"
              class="inline-flex items-center gap-1.5 pl-1.5 pr-1 max-w-48 rounded-full cursor-pointer focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500"
            >
              <.icon name="pi-check-bold" class="h-3.5 w-3.5" />
              <span class="truncate">{@cycle_label}</span>
            </button>
            <button
              type="button"
              id="cycle-previous"
              aria-label="Previous cycle"
              title="Previous cycle"
              disabled={is_nil(@previous_cycle)}
              phx-click="step_cycle"
              phx-value-number={@previous_cycle}
              class="flex items-center justify-center h-6 w-6 rounded-full text-blue-800 dark:text-blue-200 enabled:hover:bg-blue-200 dark:enabled:hover:bg-blue-800 enabled:cursor-pointer disabled:opacity-40 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500"
            >
              <.icon name="pi-caret-left-bold" class="h-3 w-3" />
            </button>
            <button
              type="button"
              id="cycle-next"
              aria-label="Next cycle"
              title="Next cycle"
              disabled={is_nil(@next_cycle)}
              phx-click="step_cycle"
              phx-value-number={@next_cycle}
              class="flex items-center justify-center h-6 w-6 rounded-full text-blue-800 dark:text-blue-200 enabled:hover:bg-blue-200 dark:enabled:hover:bg-blue-800 enabled:cursor-pointer disabled:opacity-40 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500"
            >
              <.icon name="pi-caret-right-bold" class="h-3 w-3" />
            </button>
          </div>

          <button
            :if={@show_owner_chip}
            type="button"
            id="cycle-owner-chip"
            title="Clear filter"
            phx-click="pick_owner"
            phx-value-user_id={@owner}
            class="inline-flex items-center gap-1.5 max-w-48 px-3 py-1 rounded-full text-xs font-semibold cursor-pointer bg-blue-100 dark:bg-blue-900 text-blue-800 dark:text-blue-200 border border-blue-600 dark:border-blue-500 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500"
          >
            <span class="truncate">{@owner_name}</span>
            <.icon name="pi-x-bold" class="h-3 w-3 shrink-0" />
          </button>

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
          <div :if={@view == :cycle} class="flex flex-col lg:flex-row gap-5 items-start">
            <div class="flex-1 min-w-0 w-full">
              <.empty_state :if={@issues == []} title={@empty_title} />
              <div
                :if={@issues != []}
                id="cycle-issues"
                data-qa="cycle-issues"
                class="rounded-xl border border-slate-200 dark:border-slate-700 overflow-hidden"
              >
                <section :for={group <- @groups} id={group.key} aria-label={group.label}>
                  <div class="flex items-center gap-2.5 h-10 px-4 bg-slate-50 dark:bg-slate-800/60 border-b border-slate-200 dark:border-slate-700">
                    <.status_icon state={group.state} />
                    <h3 class="min-w-0 truncate text-[13px] font-semibold text-slate-900 dark:text-slate-100">
                      {group.label}
                    </h3>
                    <span class="shrink-0 text-xs text-slate-500 dark:text-slate-400">
                      {group.count} {if group.count == 1, do: "issue", else: "issues"}
                    </span>
                    <span
                      class="shrink-0 inline-flex items-center gap-1 text-xs text-slate-500 dark:text-slate-400"
                      title={"#{group.points} points"}
                    >
                      <.icon name="pi-triangle" class="h-3 w-3" />
                      {group.points}
                    </span>
                  </div>
                  <div class="divide-y divide-slate-200 dark:divide-slate-800 border-b border-slate-200 dark:border-slate-700">
                    <.issue_rows rows={group.rows} blockers={@blockers} />
                  </div>
                </section>
              </div>
            </div>
            <.cycle_panel
              :if={@current_project}
              cycle={hd(@sections).cycle}
              progress={hd(@sections).progress}
              owner={@owner}
            />
            <.cycle_panels
              :if={is_nil(@current_project)}
              sections={@sections}
              owner={@owner}
              closed_panels={@closed_panels}
            />
          </div>

          <.empty_state :if={@view == :list and @issues == []} title={@empty_title} />

          <!-- Issues Cards List -->
          <div
            :if={@view == :list and @issues != []}
            id="issues-list"
            data-qa="issues-table issues-list"
            class="rounded-xl border border-slate-200 dark:border-slate-700 divide-y divide-slate-200 dark:divide-slate-800 overflow-hidden"
          >
            <.issue_rows rows={@rows} blockers={@blockers} />
          </div>

          <div
            :if={@view == :list and @total > 0}
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
    {:noreply, save_and_patch(socket, priority: priority, page: 1)}
  end

  # My issues and an owner both pick whose issues show, so turning one on turns the other off.
  def handle_event("toggle_mine", _params, socket) do
    mine = not socket.assigns.mine
    changes = if mine, do: [mine: true, owner: nil, page: 1], else: [mine: false, page: 1]
    {:noreply, save_and_patch(socket, changes)}
  end

  def handle_event("toggle_show_finished", _params, socket) do
    {:noreply, save_and_patch(socket, finished: not socket.assigns.show_finished, page: 1)}
  end

  # On, it opens the current cycle; off, it goes back to all issues and drops the owner, which only a cycle has.
  def handle_event("toggle_cycle", _params, socket) do
    changes =
      case socket.assigns do
        %{cycle_on: false, current_project: nil} -> [cycle: "current", page: 1]
        %{cycle_on: false, current_cycle: %{number: number}} -> [cycle: number, page: 1]
        _on -> [cycle: nil, owner: nil, page: 1]
      end

    {:noreply, save_and_patch(socket, changes)}
  end

  # Which cycle is open is not remembered, so stepping saves nothing. Across projects the arrows carry an offset.
  def handle_event("step_cycle", %{"number" => number}, socket) do
    key = if socket.assigns.current_project, do: :cycle, else: :offset
    {:noreply, push_patch(socket, to: issues_path(socket.assigns, [{key, number}, {:page, 1}]))}
  end

  # The id only goes into the set of closed panels, so it is never queried.
  def handle_event("toggle_cycle_panel", %{"project_id" => project_id}, socket) do
    closed = socket.assigns.closed_panels

    closed =
      if MapSet.member?(closed, project_id),
        do: MapSet.delete(closed, project_id),
        else: MapSet.put(closed, project_id)

    {:noreply, assign(socket, :closed_panels, closed)}
  end

  def handle_event("pick_owner", %{"user_id" => user_id}, socket) do
    changes = if socket.assigns.owner == user_id, do: [owner: nil], else: [owner: user_id, mine: false]
    {:noreply, save_and_patch(socket, changes)}
  end

  # The pull runs in the background a page at a time; the button stays busy
  # until every project it started has said it is done.
  def handle_event("sync_issues", _params, socket) do
    projects =
      if project = socket.assigns.current_project,
        do: [project],
        else: socket.assigns.projects

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

  # A change from the tracker can move an issue in or out of the filters, finished ones included, and a blocker
  # finishing takes its mark off the rows it blocked.
  def handle_info({:issue_changed, issue_id}, socket) do
    socket = reload_data(socket)

    blocker_ids =
      for {_external_id, %{blocked_by: entries}} <- socket.assigns.blockers, %{issue: %{id: id}} <- entries, do: id

    socket =
      if issue_id in blocker_ids,
        do: read_blockers(socket, socket.assigns.blockers_for, shown_issues(socket.assigns)),
        else: socket

    {:noreply, socket}
  end

  def handle_info({:issue_comments_changed, _issue_id}, socket), do: {:noreply, socket}

  def handle_info({:workflows_changed, _project_id}, socket), do: {:noreply, reload_data(socket)}

  # `:cycles` stays nil until every project has answered, so the view never gains a project after it shows. One
  # project's cycle named only as the current one is written as its number, so a reload opens the same one.
  def handle_async({:cycles, project_id}, result, socket) do
    answer =
      case result do
        {:ok, {:ok, %{cycles: cycles, statuses: statuses}}} -> %{cycles: cycles, statuses: statuses, failed: false}
        _failed -> %{cycles: [], statuses: [], failed: true}
      end

    answers = Map.put(socket.assigns.cycle_answers, project_id, answer)
    socket = assign(socket, :cycle_answers, answers)
    projects = socket.assigns.cycle_projects

    if Enum.all?(projects, &Map.has_key?(answers, &1.id)) do
      entries = for project <- projects, do: Map.put(answers[project.id], :project, project)
      socket = socket |> assign(:cycles, entries) |> reload_data()
      %{current_project: current_project, cycle_param: cycle_param, cycle_on: cycle_on} = socket.assigns

      socket =
        if current_project != nil and cycle_param == "current" and cycle_on,
          do: push_patch(socket, to: issues_path(socket.assigns, []), replace: true),
          else: socket

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  # An answer for issues the page no longer shows is dropped: a newer read is under way.
  def handle_async(:blockers, {:ok, {external_ids, blockers}}, socket) do
    if external_ids == socket.assigns.blockers_for,
      do: {:noreply, assign(socket, :blockers, blockers)},
      else: {:noreply, socket}
  end

  def handle_async(:blockers, {:exit, _reason}, socket), do: {:noreply, assign(socket, :blockers, %{})}

  attr :title, :string, required: true

  defp empty_state(assigns) do
    ~H"""
    <div
      id="issues-empty-state"
      data-qa="issues-empty-state"
      class="rounded-xl border border-slate-200 bg-slate-50 dark:border-slate-700 dark:bg-slate-800 p-12 flex flex-col items-center justify-center text-center space-y-4"
    >
      <.icon name="pi-lightbulb-fill" class="h-14 w-14 text-slate-500 dark:text-slate-400 opacity-70" />
      <h2
        class="text-base font-semibold text-slate-500 dark:text-slate-400 break-words"
        data-qa="empty-state-title"
      >
        {@title}
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
    """
  end

  attr :rows, :list, required: true
  attr :blockers, :map, required: true

  # A dimmed copy is a parent whose task is not loaded, so it carries no stage chip.
  defp issue_rows(assigns) do
    ~H"""
    <%= for row <- @rows do %>
      <.issue_card
        issue={row.issue}
        row_key={row.key}
        dimmed={row.dimmed}
        task={if(row.dimmed, do: nil, else: row.issue.task && %{row.issue.task | issue: row.issue})}
        run={if(row.dimmed, do: nil, else: stage_run(row.issue.task))}
        open_blockers={open_blockers(@blockers, row.issue)}
      />
      <.issue_card
        :for={sub <- row.sub_issues}
        issue={sub.issue}
        row_key={sub.key}
        nested
        task={sub.issue.task && %{sub.issue.task | issue: sub.issue}}
        run={stage_run(sub.issue.task)}
        open_blockers={open_blockers(@blockers, sub.issue)}
      />
    <% end %>
    """
  end

  attr :sections, :list, required: true
  attr :owner, :string, default: nil
  attr :closed_panels, :any, required: true

  # Open panels are taller than a screen, so the column scrolls with the page rather than sticking.
  defp cycle_panels(assigns) do
    ~H"""
    <aside
      id="cycle-panels"
      aria-label="Cycles"
      class="w-full lg:w-[340px] shrink-0 order-first lg:order-none rounded-xl border border-slate-200 dark:border-slate-700 bg-slate-50 dark:bg-slate-800/40 divide-y divide-slate-200 dark:divide-slate-700 overflow-hidden"
    >
      <%= for section <- @sections do %>
        <.cycle_panel
          :if={section.cycle}
          cycle={section.cycle}
          progress={section.progress}
          owner={@owner}
          project={section.project}
          open={not MapSet.member?(@closed_panels, section.project.id)}
          id_prefix={"cycle-#{section.project.key}"}
        />
        <p
          :if={section.failed}
          id={"cycle-#{section.project.key}-failed"}
          class="flex items-center gap-2.5 px-3 py-2.5 text-xs text-slate-600 dark:text-slate-300"
        >
          <.project_badge project={section.project} />
          <.icon name="pi-warning-circle" class="h-4 w-4 shrink-0 text-red-600 dark:text-red-400" />
          <span class="min-w-0">Linear did not answer, so these issues are not listed.</span>
        </p>
      <% end %>
    </aside>
    """
  end

  # Picked out of the runs already loaded rather than queried per row.
  defp stage_run(%Task{} = task), do: Task.stage_run(task)
  defp stage_run(nil), do: nil

  defp open_blockers(blockers, %Issue{external_id: external_id}),
    do: Issue.calculate_open_blockers(get_in(blockers, [external_id, :blocked_by]) || [])

  defp project_subtitle(nil), do: "Issues across all projects"

  defp project_subtitle(%{tracker: tracker, name: name} = project),
    do: "#{Issue.tracker_label(tracker)} issues in #{project.key} (#{name})"

  # --- Private Helpers ---

  # Only a Linear project has cycles to ask for, each in a read of its own so one failing loses no other's answer.
  defp load_cycles(socket, projects) do
    linear = for %Project{tracker: :linear} = project <- projects, do: project

    socket =
      socket
      |> assign(:cycle_projects, linear)
      |> assign(:cycle_answers, %{})
      |> assign(:closed_panels, MapSet.new())
      |> assign(:cycles, if(linear == [], do: []))

    if connected?(socket), do: Enum.reduce(linear, socket, &read_cycles/2), else: socket
  end

  defp read_cycles(project, socket), do: start_async(socket, {:cycles, project.id}, fn -> Issues.get_cycles(project) end)

  # A section is one project's cycle on show, if any, beside what Linear answered for it.
  defp reload_data(socket) do
    assigns = socket.assigns
    entries = assigns.cycles || []
    sections = for entry <- entries, do: Map.put(entry, :cycle, pick_cycle(entry, assigns))
    current = Enum.find_value(entries, fn entry -> Enum.find(entry.cycles, & &1.current) end)
    open = Enum.find(sections, & &1.cycle)
    offset = assigns.cycle_offset

    {label, previous, next} =
      cond do
        is_nil(open) ->
          {nil, nil, nil}

        assigns.current_project != nil ->
          {cycle_label(open.cycle), neighbor(open.cycles, open.cycle, -1), neighbor(open.cycles, open.cycle, 1)}

        true ->
          # An arrow steps to where at least one project has a cycle.
          [previous, next] =
            for step <- [offset - 1, offset + 1], do: if(Enum.any?(entries, &cycle_at(&1.cycles, step)), do: step)

          {offset_label(offset), previous, next}
      end

    socket =
      socket
      |> assign(:sections, sections)
      |> assign(:cycle_on, open != nil)
      |> assign(:current_cycle, current)
      |> assign(:show_cycle_chip, current != nil or open != nil)
      |> assign(:cycle_label, label)
      |> assign(:previous_cycle, previous)
      |> assign(:next_cycle, next)

    cond do
      # Linear has not answered yet, so the whole list never flashes up before the cycle's.
      is_binary(assigns.cycle_param) and is_nil(assigns.cycles) ->
        socket
        |> assign(:view, :loading)
        |> assign_no_owner()
        |> assign_counts([], 0, %{})

      open != nil ->
        load_cycle(socket, sections)

      true ->
        socket |> assign_no_owner() |> load_page()
    end
  end

  defp load_cycle(socket, sections) do
    assigns = socket.assigns

    sections =
      for section <- sections,
          do: Map.put(section, :progress, section.cycle && Issues.get_cycle_progress(section.project, section.cycle))

    shown = Enum.filter(sections, & &1.cycle)
    # An owner with nothing in the cycles shown is no filter at all.
    picked = shown |> Enum.flat_map(& &1.progress.owners) |> Enum.find(&(&1.user.id == assigns.owner_param))

    %{issues: issues, total: total, priority_counts: priority_counts} =
      Issues.list_issues(
        project_id: Enum.map(shown, & &1.project.id),
        cycle_id: Enum.map(shown, & &1.cycle.id),
        owner_user_id: (picked && picked.user.id) || if(assigns.mine, do: assigns.current_scope.user.id),
        show_finished: assigns.show_finished,
        search: assigns.search,
        priority: assigns.filter_priority,
        preload: @preload
      )

    empty_title =
      if assigns.current_project,
        do: "No issues in #{cycle_label(hd(shown).cycle)}",
        else: "No issues in these cycles"

    socket
    |> assign(:view, :cycle)
    |> assign(:sections, sections)
    |> assign(:owner, picked && picked.user.id)
    |> assign(:owner_name, picked && (picked.user.name || picked.user.login))
    |> assign(:show_owner_chip, picked != nil and is_nil(assigns.current_project))
    |> assign(:groups, status_groups(issues, shown, assigns.current_project))
    |> assign(:empty_title, empty_title)
    |> assign_counts(issues, total, priority_counts)
    |> watch_blockers()
  end

  # Across projects the most pressing come first; the sort is stable, so the latest update still breaks ties.
  defp status_groups(issues, shown, current_project) do
    rank = Issue.priorities() |> Enum.with_index() |> Map.new()
    rows = if current_project, do: issues, else: Enum.sort_by(issues, &rank[&1.priority])
    statuses = shown |> Enum.flat_map(& &1.statuses) |> Enum.uniq_by(& &1.name)
    estimates = Map.new(shown, &{&1.project.id, &1.cycle.default_estimate})
    Issue.calculate_status_groups(rows, statuses, estimates)
  end

  defp assign_no_owner(socket) do
    socket
    |> assign(:owner, nil)
    |> assign(:owner_name, nil)
    |> assign(:show_owner_chip, false)
  end

  defp load_page(socket) do
    assigns = socket.assigns
    offset = (assigns.page - 1) * @page_size

    %{issues: issues, total: total, priority_counts: priority_counts} =
      Issues.list_issues(
        project_id: assigns.project_filter,
        owner_user_id: if(assigns.mine, do: assigns.current_scope.user.id),
        show_finished: assigns.show_finished,
        search: assigns.search,
        priority: assigns.filter_priority,
        limit: @page_size,
        offset: offset,
        preload: @preload
      )

    last_page = max(div(total + @page_size - 1, @page_size), 1)

    # A linked page past the end (fewer matches since) shows the last one instead.
    if assigns.page > last_page do
      socket |> assign(:page, last_page) |> load_page()
    else
      socket
      |> assign(:view, :list)
      |> assign(:rows, Issue.calculate_issue_tree(issues))
      |> assign(
        :empty_title,
        if(String.trim(assigns.search) == "", do: "No issues in this view", else: "No issues match")
      )
      |> assign_counts(issues, total, priority_counts)
      |> assign_pages(total, offset)
      |> watch_blockers()
    end
  end

  defp assign_counts(socket, issues, total, priority_counts) do
    socket
    |> assign(:issues, issues)
    |> assign(:total, total)
    |> assign(:priority_counts, priority_counts)
    |> assign(:all_count, priority_counts |> Map.values() |> Enum.sum())
  end

  defp assign_pages(socket, total, offset) do
    assigns = socket.assigns

    socket
    |> assign(:page_first, min(offset + 1, total))
    |> assign(:page_last, min(offset + @page_size, total))
    |> assign(:prev_path, if(assigns.page > 1, do: issues_path(assigns, page: assigns.page - 1)))
    |> assign(:next_path, if(offset + @page_size < total, do: issues_path(assigns, page: assigns.page + 1)))
  end

  # Linear sends nothing when a relation changes, so blockers are read again whenever the rows on the page change.
  defp watch_blockers(socket) do
    issues = shown_issues(socket.assigns)
    external_ids = issues |> Enum.map(& &1.external_id) |> Enum.uniq() |> Enum.sort()

    if external_ids == socket.assigns.blockers_for,
      do: socket,
      else: read_blockers(socket, external_ids, issues)
  end

  defp read_blockers(socket, [], _issues), do: socket |> assign(:blockers_for, []) |> assign(:blockers, %{})

  defp read_blockers(socket, external_ids, issues) do
    socket = assign(socket, :blockers_for, external_ids)

    if connected?(socket),
      do: start_async(socket, :blockers, fn -> {external_ids, Issues.get_blockers(issues)} end),
      else: socket
  end

  # Every issue a row shows, dimmed parents included.
  defp shown_issues(%{view: :cycle, groups: groups}), do: Enum.flat_map(groups, &row_issues(&1.rows))
  defp shown_issues(%{view: :list, rows: rows}), do: row_issues(rows)

  defp row_issues(rows), do: Enum.flat_map(rows, fn row -> [row.issue | Enum.map(row.sub_issues, & &1.issue)] end)

  defp pick_cycle(%{cycles: cycles}, %{current_project: nil, cycle_param: "current", cycle_offset: offset}),
    do: cycle_at(cycles, offset)

  # No one number names several teams' cycles.
  defp pick_cycle(_entry, %{current_project: nil}), do: nil

  defp pick_cycle(%{cycles: cycles}, assigns),
    do: find_cycle(cycles, Enum.find(cycles, & &1.current), assigns.cycle_param)

  # Counted from the project's current cycle, so a project with none has nowhere to count from.
  defp cycle_at(cycles, offset) do
    current = Enum.find_index(cycles, & &1.current)
    index = current && current + offset
    if is_integer(index) and index >= 0, do: Enum.at(cycles, index)
  end

  defp find_cycle(_cycles, current, "current"), do: current

  defp find_cycle(cycles, _current, number) when is_binary(number),
    do: Enum.find(cycles, &(Integer.to_string(&1.number) == number))

  defp find_cycle(_cycles, _current, nil), do: nil

  defp neighbor(cycles, cycle, step) do
    index = Enum.find_index(cycles, &(&1.id == cycle.id)) + step
    if index >= 0, do: cycles |> Enum.at(index) |> then(&(&1 && &1.number))
  end

  defp cycle_label(cycle), do: cycle.name || "Cycle #{cycle.number}"

  defp offset_label(0), do: "Current cycles"
  defp offset_label(-1), do: "Previous cycles"
  defp offset_label(1), do: "Next cycles"
  defp offset_label(offset) when offset < 0, do: "#{-offset} cycles back"
  defp offset_label(offset), do: "#{offset} cycles ahead"

  # Every remembered filter is saved as it will now read, replacing what was there, before the patch shows it.
  defp save_and_patch(socket, changes) do
    params = issue_params(socket.assigns, changes)

    filters =
      for {key, value} <- params, to_string(key) in @remembered, into: %{} do
        {to_string(key), if(key == :cycle, do: "current", else: to_string(value))}
      end

    # Where no chip shows, a saved cycle view and owner are kept, since the person could not have turned them off here.
    kept =
      cond do
        socket.assigns.show_cycle_chip or Map.has_key?(filters, "cycle") -> %{}
        Map.has_key?(filters, "mine") -> Map.take(socket.assigns.saved_filters, ["cycle"])
        true -> Map.take(socket.assigns.saved_filters, ["cycle", "owner"])
      end

    {:ok, %User{issues_filters: saved}} =
      Users.set_issues_filters(socket.assigns.current_scope, Map.merge(kept, filters))

    socket
    |> assign(:saved_filters, saved)
    |> push_patch(to: params_path(params))
  end

  defp issues_path(assigns, changes), do: assigns |> issue_params(changes) |> params_path()

  # Defaults stay out of the URL, so the plain list is still just /issues. One project's cycle is its number once
  # Linear has answered, every project's is current and an offset, and either is dropped when nothing shows.
  defp issue_params(assigns, changes) do
    {cycle, offset, owner} =
      cond do
        assigns.cycle_on and assigns.current_project != nil -> {hd(assigns.sections).cycle.number, 0, assigns.owner}
        assigns.cycle_on -> {"current", assigns.cycle_offset, assigns.owner}
        is_nil(assigns.cycles) -> {assigns.cycle_param, assigns.cycle_offset, assigns.owner_param}
        true -> {nil, 0, nil}
      end

    current = [
      q: assigns.search,
      priority: assigns.filter_priority,
      mine: assigns.mine,
      finished: assigns.show_finished,
      cycle: cycle,
      offset: offset,
      owner: owner,
      page: assigns.page
    ]

    # Each key keeps its place, so the same filters always read as the same URL.
    params = for {key, value} <- current, do: {key, Keyword.get(changes, key, value)}

    params =
      if params[:cycle] in [nil, ""],
        do: params |> Keyword.put(:owner, nil) |> Keyword.put(:offset, 0),
        else: params

    Enum.reject(params, fn {key, value} ->
      value in [nil, "", false, "all"] or {key, to_string(value)} in [{:page, "1"}, {:offset, "0"}]
    end)
  end

  defp params_path([]), do: ~p"/issues"
  defp params_path(params), do: ~p"/issues?#{params}"

  defp remembered_path(filters) do
    params =
      for key <- [:q, :priority, :mine, :finished, :cycle, :owner, :page],
          value = filters[to_string(key)],
          do: {key, value}

    params_path(params)
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

  defp cycle_offset(value) when is_binary(value) do
    case Integer.parse(value) do
      {offset, ""} -> offset
      _invalid -> 0
    end
  end

  defp cycle_offset(_missing), do: 0
end
