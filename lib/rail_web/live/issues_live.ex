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
  @no_cycles %{cycles: [], statuses: []}
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
      |> load_cycles(project)

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
            :if={@show_cycle_chip and is_nil(@cycle)}
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
            :if={@show_cycle_chip and @cycle != nil}
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
            <.cycle_panel cycle={@cycle} progress={@progress} owner={@owner} />
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
        %{cycle: nil, current_cycle: %{number: number}} -> [cycle: number, page: 1]
        _on -> [cycle: nil, owner: nil, page: 1]
      end

    {:noreply, save_and_patch(socket, changes)}
  end

  # Which cycle is open is not remembered, so stepping saves nothing.
  def handle_event("step_cycle", %{"number" => number}, socket) do
    {:noreply, push_patch(socket, to: issues_path(socket.assigns, cycle: number, page: 1))}
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

  # A cycle the URL names only as the current one is written as its number, so a reload opens the same one.
  def handle_async(:cycles, {:ok, {:ok, cycles}}, socket) do
    socket = socket |> assign(:cycles, cycles) |> reload_data()

    socket =
      if socket.assigns.cycle_param == "current" and socket.assigns.cycle != nil,
        do: push_patch(socket, to: issues_path(socket.assigns, []), replace: true),
        else: socket

    {:noreply, socket}
  end

  def handle_async(:cycles, _failed, socket) do
    socket = socket |> assign(:cycles, @no_cycles) |> reload_data()
    {:noreply, socket}
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

  # Picked out of the runs already loaded rather than queried per row.
  defp stage_run(%Task{} = task), do: Task.stage_run(task)
  defp stage_run(nil), do: nil

  defp open_blockers(blockers, %Issue{external_id: external_id}),
    do: Issue.calculate_open_blockers(get_in(blockers, [external_id, :blocked_by]) || [])

  defp project_subtitle(nil), do: "Issues across all projects"

  defp project_subtitle(%{tracker: tracker, name: name} = project),
    do: "#{Issue.tracker_label(tracker)} issues in #{project.key} (#{name})"

  # --- Private Helpers ---

  # Only a Linear project has cycles to ask for; the page does not wait on the answer.
  defp load_cycles(socket, %Project{tracker: :linear} = project) do
    socket = assign(socket, :cycles, nil)
    if connected?(socket), do: start_async(socket, :cycles, fn -> Issues.get_cycles(project) end), else: socket
  end

  defp load_cycles(socket, _github_or_all), do: assign(socket, :cycles, @no_cycles)

  defp reload_data(socket) do
    assigns = socket.assigns
    cycles = assigns.cycles || @no_cycles
    current = Enum.find(cycles.cycles, & &1.current)
    cycle = find_cycle(cycles.cycles, current, assigns.cycle_param)

    socket =
      socket
      |> assign(:cycle, cycle)
      |> assign(:current_cycle, current)
      |> assign(:show_cycle_chip, current != nil or cycle != nil)
      |> assign(:cycle_label, cycle && cycle_label(cycle))
      |> assign(:previous_cycle, cycle && neighbor(cycles.cycles, cycle, -1))
      |> assign(:next_cycle, cycle && neighbor(cycles.cycles, cycle, 1))

    cond do
      # Linear has not answered yet, so the whole list never flashes up before the cycle's.
      is_binary(assigns.cycle_param) and is_nil(assigns.cycles) ->
        socket
        |> assign(:view, :loading)
        |> assign(:owner, nil)
        |> assign_counts([], 0, %{})

      cycle != nil ->
        load_cycle(socket, cycle, cycles.statuses)

      true ->
        socket |> assign(:owner, nil) |> load_page()
    end
  end

  defp load_cycle(socket, cycle, statuses) do
    assigns = socket.assigns
    progress = Issues.get_cycle_progress(assigns.current_project, cycle)
    # An owner with nothing in the cycle is no filter at all.
    owner = if Enum.any?(progress.owners, &(&1.user.id == assigns.owner_param)), do: assigns.owner_param

    %{issues: issues, total: total, priority_counts: priority_counts} =
      Issues.list_issues(
        project_id: assigns.current_project.id,
        cycle_id: cycle.id,
        owner_user_id: owner || if(assigns.mine, do: assigns.current_scope.user.id),
        show_finished: assigns.show_finished,
        search: assigns.search,
        priority: assigns.filter_priority,
        preload: @preload
      )

    socket
    |> assign(:view, :cycle)
    |> assign(:owner, owner)
    |> assign(:progress, progress)
    |> assign(:groups, Issue.calculate_status_groups(issues, statuses, cycle.default_estimate))
    |> assign(:empty_title, "No issues in #{cycle_label(cycle)}")
    |> assign_counts(issues, total, priority_counts)
    |> watch_blockers()
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

  defp find_cycle(_cycles, current, "current"), do: current

  defp find_cycle(cycles, _current, number) when is_binary(number),
    do: Enum.find(cycles, &(Integer.to_string(&1.number) == number))

  defp find_cycle(_cycles, _current, nil), do: nil

  defp neighbor(cycles, cycle, step) do
    index = Enum.find_index(cycles, &(&1.id == cycle.id)) + step
    if index >= 0, do: cycles |> Enum.at(index) |> then(&(&1 && &1.number))
  end

  defp cycle_label(cycle), do: cycle.name || "Cycle #{cycle.number}"

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

  # Defaults stay out of the URL, so the plain list is still just /issues. The cycle is its number once Linear has
  # answered, and dropped when the project has no such cycle; the owner goes with it.
  defp issue_params(assigns, changes) do
    {cycle, owner} =
      cond do
        assigns.cycle != nil -> {assigns.cycle.number, assigns.owner}
        is_nil(assigns.cycles) -> {assigns.cycle_param, assigns.owner_param}
        true -> {nil, nil}
      end

    current = [
      q: assigns.search,
      priority: assigns.filter_priority,
      mine: assigns.mine,
      finished: assigns.show_finished,
      cycle: cycle,
      owner: owner,
      page: assigns.page
    ]

    # Each key keeps its place, so the same filters always read as the same URL.
    params = for {key, value} <- current, do: {key, Keyword.get(changes, key, value)}
    params = if params[:cycle] in [nil, ""], do: Keyword.put(params, :owner, nil), else: params
    Enum.reject(params, fn {key, value} -> value in [nil, "", false, "all"] or {key, value} == {:page, 1} end)
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
end
