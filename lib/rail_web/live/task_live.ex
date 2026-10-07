defmodule RailWeb.TaskLive do
  @moduledoc """
  One task, read a tab at a time: the issue it came from, then a tab per role
  with that role's work on the left and its conversation on the right.

  A tab is the whole page - the work and the conversation move together - and it
  is in the URL, so a refresh comes back to it. The role a human picks stays
  picked until the task moves to another stage, when the role for the new stage
  takes the page over. A role that has not run has nothing to read, so it has no
  tab until it does.

  A split parent's page adds a Children tab, a board of its children, right after Plan. A child is shown
  on its parent's page, named in the URL, with the same tab and a switcher to its siblings.

  The page owns what the components cannot: the subscriptions. A LiveComponent
  may not subscribe, so log lines arrive here and are forwarded to the
  conversation, and a saved output to the open stage, with `send_update/2`.
  """
  use RailWeb, :live_view

  import RailWeb.Utils.ChildStatus
  import RailWeb.Utils.HandleIssueEvent

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Learnings
  alias Rail.Learnings.Schemas.Learning
  alias Rail.Learnings.Schemas.Observation
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Roles.Schemas.Role
  alias Rail.Scope
  alias Rail.Tools
  alias Rail.Users
  alias RailWeb.Live.DemoStage
  alias RailWeb.Live.EngineerStage
  alias RailWeb.Live.PlanStage
  alias RailWeb.Live.QaStage
  alias RailWeb.Live.QuestionCard
  alias RailWeb.Live.ReviewStage
  alias RailWeb.Live.RunConversation

  # The engineer writes files as it works and the pane reads them off disk, so a
  # reader watching a run wants the diff to keep up. Re-reading on every batch of
  # log lines would shell out to git several times a second, so it is throttled to
  # this; the turn finishing re-reads regardless of when the last one was.
  @diff_refresh_ms 5_000

  # A full-size frame is a few hundred KB, so four a second is still a live
  # picture but a load any viewer's connection can keep up with.
  @frame_interval_ms 250

  @issue_tab "issue"
  @children_tab "children"

  # What the Issue tab's owner menu and comments raise, handled as the issue page handles them.
  @issue_events ["assign", "filter_assignees", "draft_comment", "comment"]

  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:task, nil)
      |> assign(:task_id, nil)
      |> assign(:page_title, "Task")
      |> assign(:current_section, :tasks)
      |> assign(:selected_tab, nil)
      |> assign(:url_tab, nil)
      |> assign(:tab_stage, nil)
      |> assign(:selected_role, nil)
      |> assign(:selected_run, nil)
      |> assign(:stage_run, nil)
      |> assign(:line, nil)
      |> assign(:conversation_run, nil)
      |> assign(:pane, :issue)
      |> assign(:diff_refreshed_at, nil)
      |> assign(:approvable, false)
      |> assign(:tabs, [])
      |> assign(:issue, nil)
      |> assign(:assignees, [])
      |> assign(:assignee_query, "")
      |> assign(:comment_nonce, 0)
      |> assign(:subscribed_run_ids, MapSet.new())
      |> assign(:watched_browser_task_id, nil)
      |> assign(:watched_comments_task_id, nil)
      |> assign(:watched_outputs_task_id, nil)
      |> assign(:frame_window_open?, false)
      |> assign(:held_frame, nil)
      |> assign(:roles_map, %{})
      |> assign(:round_questions, [])
      |> assign(:suggestions, %{})
      |> assign(:cleaning_up, false)
      |> assign(:focus_file, nil)
      |> assign(:engineer_tab, nil)
      |> assign(:url_id, nil)
      |> assign(:child, nil)
      |> assign(:parent, nil)
      |> assign(:statuses, [])
      |> assign(:family_ids, MapSet.new())
      |> assign(:family_issue_ids, MapSet.new())
      |> assign(:watching_issues, false)
      |> assign(:show_switcher, false)
      |> assign(:header_status, nil)
      |> assign(:child_of, nil)
      |> assign(:split_points, nil)
      |> assign(:cleanup_confirm, nil)
      |> assign(:viewer_owns, false)

    # A stage moved from another page or by a run finishing is what keeps this one current.
    if connected?(socket), do: Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline")

    {:ok, socket}
  end

  def handle_params(%{"id" => task_id} = params, _uri, socket) do
    # The board is the parent's, so a child named beside it is left for the board.
    child = if params["tab"] != @children_tab, do: params["child"]

    socket =
      socket
      |> assign(:url_id, task_id)
      |> assign(:task_id, task_id)
      |> assign(:child, child)
      |> assign(:url_tab, params["tab"])
      |> assign(:selected_tab, params["tab"])
      |> assign(:focus_file, params["file"])
      |> refresh_task()

    {:noreply, socket}
  end

  def render(assigns) do
    ~H"""
    <%!-- Named rather than spread: a spread redraws the whole page for any assign,
    such as each diff refresh's timestamp. --%>
    <Layouts.app
      flash={@flash}
      current_section={@current_section}
      current_scope={@current_scope}
      is_rail_extended={@is_rail_extended}
      attention_count={@attention_count}
      triage_count={@triage_count}
      current_project_id={@current_project_id}
      projects={@projects}
      theme={@theme}
      show_project_switcher={@show_project_switcher}
      lost_backends={@lost_backends}
    >
      <div id="task-page" data-qa="task-page" class="contents">
        <div
          :if={@task == nil}
          id="task-cleaned-up"
          data-qa="task-cleaned-up"
          class="flex flex-col items-center justify-center min-h-[300px] text-center p-8 bg-white dark:bg-slate-900 rounded-xl border border-slate-200 dark:border-slate-700 shadow-xs"
        >
          <p class="text-base font-medium text-slate-500 dark:text-slate-400">
            This task has been cleaned up.
          </p>
        </div>

        <.live_component
          :if={@task != nil and @pane == :plan}
          module={PlanStage}
          id={stage_component_id(@selected_role)}
          current_scope={@current_scope}
          task={@task}
          run={@selected_run}
          stage_run={@stage_run}
          line={@line}
          approvable={@approvable}
          status={@header_status}
          child_of={@child_of}
        >
          <:breadcrumb :if={@show_switcher}>
            <.child_switcher
              statuses={@statuses}
              current_id={@task.id}
              parent={@parent}
              viewer_owns={@viewer_owns}
            />
          </:breadcrumb>
          <:tabs><.task_tabs tabs={@tabs} /></:tabs>
          <:actions>
            <.claim_button task={@task} />
            <.update_branch_button task={@task} engineer_tab={@engineer_tab} />
            <.cleanup_button task={@task} cleaning_up={@cleaning_up} confirm={@cleanup_confirm} />
          </:actions>
          <:sidebar>
            <.conversation_sidebar
              task={@task}
              current_scope={@current_scope}
              roles_map={@roles_map}
              round_questions={@round_questions}
              suggestions={@suggestions}
              conversation_run={@conversation_run}
            />
          </:sidebar>
        </.live_component>

        <.live_component
          :if={@task != nil and @pane == :engineer}
          module={EngineerStage}
          id={stage_component_id(@selected_role)}
          task={@task}
          run={@selected_run}
          stage_run={@stage_run}
          line={@line}
          approvable={@approvable}
          current_scope={@current_scope}
          focus_file={@focus_file}
        >
          <:breadcrumb :if={@show_switcher}>
            <.child_switcher
              statuses={@statuses}
              current_id={@task.id}
              parent={@parent}
              viewer_owns={@viewer_owns}
            />
          </:breadcrumb>
          <:tabs><.task_tabs tabs={@tabs} /></:tabs>
          <:actions>
            <.claim_button task={@task} />
            <.update_branch_button task={@task} engineer_tab={@engineer_tab} />
            <.cleanup_button task={@task} cleaning_up={@cleaning_up} confirm={@cleanup_confirm} />
          </:actions>
          <:sidebar>
            <.conversation_sidebar
              task={@task}
              current_scope={@current_scope}
              roles_map={@roles_map}
              round_questions={@round_questions}
              suggestions={@suggestions}
              conversation_run={@conversation_run}
            />
          </:sidebar>
        </.live_component>

        <.live_component
          :if={@task != nil and @pane == :review}
          module={ReviewStage}
          id={stage_component_id(@selected_role)}
          task={@task}
          run={@selected_run}
          stage_run={@stage_run}
          line={@line}
          approvable={@approvable}
          current_scope={@current_scope}
          engineer_tab={@engineer_tab}
        >
          <:breadcrumb :if={@show_switcher}>
            <.child_switcher
              statuses={@statuses}
              current_id={@task.id}
              parent={@parent}
              viewer_owns={@viewer_owns}
            />
          </:breadcrumb>
          <:tabs><.task_tabs tabs={@tabs} /></:tabs>
          <:actions>
            <.claim_button task={@task} />
            <.update_branch_button task={@task} engineer_tab={@engineer_tab} />
            <.cleanup_button task={@task} cleaning_up={@cleaning_up} confirm={@cleanup_confirm} />
          </:actions>
          <:sidebar>
            <.conversation_sidebar
              task={@task}
              current_scope={@current_scope}
              roles_map={@roles_map}
              round_questions={@round_questions}
              suggestions={@suggestions}
              conversation_run={@conversation_run}
            />
          </:sidebar>
        </.live_component>

        <.live_component
          :if={@task != nil and @pane == :qa}
          module={QaStage}
          id={stage_component_id(@selected_role)}
          task={@task}
          run={@selected_run}
          stage_run={@stage_run}
          line={@line}
          approvable={@approvable}
          current_scope={@current_scope}
        >
          <:breadcrumb :if={@show_switcher}>
            <.child_switcher
              statuses={@statuses}
              current_id={@task.id}
              parent={@parent}
              viewer_owns={@viewer_owns}
            />
          </:breadcrumb>
          <:tabs><.task_tabs tabs={@tabs} /></:tabs>
          <:actions>
            <.claim_button task={@task} />
            <.update_branch_button task={@task} engineer_tab={@engineer_tab} />
            <.cleanup_button task={@task} cleaning_up={@cleaning_up} confirm={@cleanup_confirm} />
          </:actions>
          <:sidebar>
            <.conversation_sidebar
              task={@task}
              current_scope={@current_scope}
              roles_map={@roles_map}
              round_questions={@round_questions}
              suggestions={@suggestions}
              conversation_run={@conversation_run}
            />
          </:sidebar>
        </.live_component>

        <.live_component
          :if={@task != nil and @pane == :demo}
          module={DemoStage}
          id={stage_component_id(@selected_role)}
          task={@task}
          run={@selected_run}
          stage_run={@stage_run}
          line={@line}
          approvable={@approvable}
          current_scope={@current_scope}
        >
          <:breadcrumb :if={@show_switcher}>
            <.child_switcher
              statuses={@statuses}
              current_id={@task.id}
              parent={@parent}
              viewer_owns={@viewer_owns}
            />
          </:breadcrumb>
          <:tabs><.task_tabs tabs={@tabs} /></:tabs>
          <:actions>
            <.claim_button task={@task} />
            <.update_branch_button task={@task} engineer_tab={@engineer_tab} />
            <.cleanup_button task={@task} cleaning_up={@cleaning_up} confirm={@cleanup_confirm} />
          </:actions>
          <:sidebar>
            <.conversation_sidebar
              task={@task}
              current_scope={@current_scope}
              roles_map={@roles_map}
              round_questions={@round_questions}
              suggestions={@suggestions}
              conversation_run={@conversation_run}
            />
          </:sidebar>
        </.live_component>

        <!-- The issue is the same view the issue page shows, and it is read on its
        own: there is no one role whose conversation belongs beside it. -->
        <.task_layout
          :if={@task != nil and @pane == :issue and @issue != nil}
          task={@task}
          stage_run={@stage_run}
          line={@line}
          title={@task.issue.title}
          status={@header_status}
        >
          <:breadcrumb :if={@show_switcher}>
            <.child_switcher
              statuses={@statuses}
              current_id={@task.id}
              parent={@parent}
              viewer_owns={@viewer_owns}
            />
          </:breadcrumb>
          <:tabs><.task_tabs tabs={@tabs} /></:tabs>
          <:actions>
            <.claim_button task={@task} />
            <.update_branch_button task={@task} engineer_tab={@engineer_tab} />
            <.cleanup_button task={@task} cleaning_up={@cleaning_up} confirm={@cleanup_confirm} />
          </:actions>
          <.issue_view
            issue={@issue}
            assignees={@assignees}
            assignee_query={@assignee_query}
            comment_nonce={@comment_nonce}
            show_task={false}
            owner_editable={@task.parent_task_id == nil}
          />
        </.task_layout>

        <.task_layout
          :if={@task != nil and @pane == :children}
          task={@task}
          stage_run={@stage_run}
          line={@line}
          title={@task.issue.title}
          status={@header_status}
        >
          <:tabs><.task_tabs tabs={@tabs} /></:tabs>
          <:meta>
            <span :if={@split_points} id="split-points">{@split_points}</span>
          </:meta>
          <:actions>
            <.claim_button task={@task} />
            <.cleanup_button task={@task} cleaning_up={@cleaning_up} confirm={@cleanup_confirm} />
          </:actions>
          <.split_board statuses={@statuses} parent_id={@parent.id} />
        </.task_layout>

        <.task_layout
          :if={@task != nil and @pane == :none}
          task={@task}
          run={@selected_run}
          stage_run={@stage_run}
          line={@line}
          title={@task.issue.title}
          status={@header_status}
        >
          <:breadcrumb :if={@show_switcher}>
            <.child_switcher
              statuses={@statuses}
              current_id={@task.id}
              parent={@parent}
              viewer_owns={@viewer_owns}
            />
          </:breadcrumb>
          <:tabs><.task_tabs tabs={@tabs} /></:tabs>
          <:actions>
            <.claim_button task={@task} />
            <.update_branch_button task={@task} engineer_tab={@engineer_tab} />
            <.cleanup_button task={@task} cleaning_up={@cleaning_up} confirm={@cleanup_confirm} />
          </:actions>
          <div
            id="role-no-work"
            data-qa="role_no_work"
            class="max-w-3xl mx-auto text-sm text-slate-500 dark:text-slate-400"
          >
            This role has nothing to show here. Its conversation is on the right.
          </div>
          <:sidebar>
            <.conversation_sidebar
              task={@task}
              current_scope={@current_scope}
              roles_map={@roles_map}
              round_questions={@round_questions}
              suggestions={@suggestions}
              conversation_run={@conversation_run}
            />
          </:sidebar>
        </.task_layout>
      </div>
    </Layouts.app>
    """
  end

  def handle_event(event, params, socket) when event in @issue_events do
    {:noreply, handle_issue_event(event, params, socket, &refresh_task/1)}
  end

  # The board is the parent's, so a child's Children tab goes back to it.
  def handle_event("select_tab", %{"tab" => @children_tab}, socket) do
    {:noreply, push_patch(socket, to: ~p"/tasks/#{socket.assigns.parent.id}?tab=#{@children_tab}")}
  end

  def handle_event("select_tab", %{"tab" => tab}, socket) do
    {:noreply, push_patch(socket, to: task_path(socket, tab))}
  end

  def handle_event("cleanup", _params, socket) do
    task = socket.assigns.task

    socket =
      socket
      |> assign(:cleaning_up, true)
      |> start_async(:cleanup, fn -> Pipeline.cleanup_task(task) end)

    {:noreply, socket}
  end

  def handle_event("claim", _params, socket) do
    socket =
      case Issues.claim_issue(socket.assigns.current_scope, socket.assigns.task.issue) do
        {:ok, issue} ->
          {:ok, _children} = Pipeline.share_owner_with_children(issue)
          socket

        {:error, reason} ->
          put_flash(socket, :error, claim_error(reason))
      end

    {:noreply, refresh_task(socket)}
  end

  def handle_event("update_branch", _params, socket) do
    socket =
      case Pipeline.update_branch(socket.assigns.current_scope, socket.assigns.task) do
        {:ok, _task} -> socket
        {:error, reason} -> put_flash(socket, :error, update_branch_error(reason))
      end

    # The merge is the engineer's work, and its tab is where it shows.
    {:noreply, push_patch(socket, to: task_path(socket, socket.assigns.engineer_tab))}
  end

  def handle_info({:run_events, run_id, events}, socket) do
    if MapSet.member?(socket.assigns.subscribed_run_ids, run_id) do
      send_update(RunConversation, id: "run-conversation", run_id: run_id, appended_events: events)
    end

    socket = refresh_diff(socket)

    {:noreply, socket}
  end

  # A frame goes to the client rather than through the component. It is a picture
  # arriving several times a second and nothing on the page depends on it, so
  # re-rendering the panel around it would be paying for a diff of everything
  # else to move one image.
  #
  # Chrome paints as often as the page moves, which on an animated page is dozens
  # of full-size frames a second - more than the socket to a viewer can carry, and
  # every click waits behind the pictures queued ahead of it. So a viewer gets at
  # most one per window: the newest frame that arrives during a window goes out when
  # it closes, and the rest are dropped, since each one only replaces the last.
  def handle_info({:browser_frame, task_id, data}, socket) do
    cond do
      socket.assigns.task_id != task_id or socket.assigns.pane not in [:qa, :demo] ->
        {:noreply, socket}

      socket.assigns.frame_window_open? ->
        {:noreply, assign(socket, :held_frame, data)}

      true ->
        {:noreply, push_frame(socket, data)}
    end
  end

  def handle_info(:frame_window_closed, socket) do
    case socket.assigns.held_frame do
      data when is_binary(data) -> {:noreply, push_frame(assign(socket, :held_frame, nil), data)}
      nil -> {:noreply, assign(socket, :frame_window_open?, false)}
    end
  end

  # Comments the reader sees moved, in another tab or this one. Only the comments
  # are read again: the diff under them has not moved.
  def handle_info({:diff_comments_changed, task_id}, socket) do
    with %{pane: :engineer, task_id: ^task_id, selected_role: %Role{} = role} <- socket.assigns do
      send_update(EngineerStage, id: stage_component_id(role), reload_comments: true)
    end

    {:noreply, socket}
  end

  # A queued message went out, or came back, on its own time.
  def handle_info({:run_changed, _run_id}, socket) do
    {:noreply, refresh_task(socket)}
  end

  # A finished turn may have left the stage in a state its panel reads differently,
  # so the stage is told to read again rather than left to notice.
  def handle_info({:os_process_finished, _run, _outcome}, socket) do
    socket = refresh_task(socket)
    reload_stage(socket)

    {:noreply, socket}
  end

  def handle_info({:pipeline_changed, task_id}, %{assigns: %{task_id: task_id}} = socket) do
    {:noreply, refresh_task(socket)}
  end

  # A split's parent and children are one page, so a move in any of them redraws it.
  def handle_info({:pipeline_changed, task_id}, socket) do
    if MapSet.member?(socket.assigns.family_ids, task_id),
      do: {:noreply, refresh_task(socket)},
      else: {:noreply, socket}
  end

  # A child's issue completing in Linear is what merges it.
  def handle_info({:issue_changed, issue_id}, socket) do
    if MapSet.member?(socket.assigns.family_issue_ids, issue_id),
      do: {:noreply, refresh_task(socket)},
      else: {:noreply, socket}
  end

  def handle_info({event, _id}, socket) when event in [:issue_created, :issue_comments_changed, :issues_synced] do
    {:noreply, socket}
  end

  # An agent saved a ticket, an option, a plan, a finding or a picture, in this
  # task, while its run is still going.
  def handle_info({:output_saved, task_id}, socket) do
    if socket.assigns.task_id == task_id, do: reload_stage(socket)

    {:noreply, socket}
  end

  # A stage sends this once the human picks or approves something on it.
  def handle_info(:task_changed, socket) do
    {:noreply, refresh_task(socket)}
  end

  # A round sent from another tab or by another person can land between opening a
  # change and saving it. The card's own flash would not reach the layout.
  def handle_info(:round_already_sent, socket) do
    socket =
      socket
      |> put_flash(:error, "This round was already sent, so its answers can no longer be changed.")
      |> refresh_task()

    {:noreply, socket}
  end

  # A cleaned-up task is gone, so the issue is where it can be started again.
  def handle_async(:cleanup, {:ok, {:ok, %Task{issue_id: issue_id}}}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/issues/#{issue_id}")}
  end

  def handle_async(:cleanup, {:ok, {:error, :task_busy}}, socket) do
    socket =
      socket
      |> assign(:cleaning_up, false)
      |> put_flash(:error, "Stop the task's run before cleaning it up")
      |> refresh_task()

    {:noreply, socket}
  end

  def handle_async(:cleanup, _result, socket) do
    socket =
      socket
      |> assign(:cleaning_up, false)
      |> put_flash(:error, "Could not clean up the task")
      |> refresh_task()

    {:noreply, socket}
  end

  attr :task, :any, required: true
  attr :engineer_tab, :any, required: true

  # Only a branch the engineer has built has anything to merge into, and only a
  # task nothing is working on can have its branch updated under it.
  defp update_branch_button(assigns) do
    ~H"""
    <button
      :if={@task.cleaned_up_at == nil and @engineer_tab != nil}
      type="button"
      id="update-branch"
      data-qa="update_branch"
      phx-click="update_branch"
      phx-disable-with="Updating…"
      disabled={Task.running?(@task)}
      title={"Merge origin/#{@task.project.default_branch} into this branch"}
      class="px-4 py-2 rounded-lg border border-slate-300 dark:border-slate-600 text-sm font-semibold text-slate-900 dark:text-slate-100 hover:bg-slate-50 dark:hover:bg-slate-800 cursor-pointer disabled:opacity-50 disabled:cursor-not-allowed"
    >
      {if @task.is_updating_branch and Task.running?(@task), do: "Updating…", else: "Update branch"}
    </button>
    """
  end

  attr :task, :any, required: true

  # Nobody owns an issue until somebody claims it, and a child of a split is owned through its parent.
  defp claim_button(assigns) do
    ~H"""
    <button
      :if={
        @task.cleaned_up_at == nil and @task.issue.owner_user_id == nil and
          @task.parent_task_id == nil
      }
      type="button"
      id="claim-task"
      data-qa="claim_task"
      phx-click="claim"
      class="px-4 py-2 rounded-lg bg-blue-600 dark:bg-blue-500 text-sm font-semibold text-white hover:opacity-90 cursor-pointer"
    >
      Claim
    </button>
    """
  end

  attr :task, :any, required: true
  attr :cleaning_up, :boolean, required: true
  attr :confirm, :string, required: true

  # A cleaned-up task is history: there is nothing left on disk to clean. A child goes with its parent.
  defp cleanup_button(assigns) do
    ~H"""
    <button
      :if={@task.cleaned_up_at == nil and @task.parent_task_id == nil}
      type="button"
      id="cleanup-task"
      data-qa="cleanup_task"
      phx-click="cleanup"
      data-confirm={@confirm}
      disabled={@cleaning_up}
      class="px-4 py-2 rounded-lg border border-red-300 dark:border-red-800 text-sm font-semibold text-red-600 dark:text-red-400 hover:bg-red-50 dark:hover:bg-red-950 cursor-pointer disabled:opacity-50"
    >
      {if @cleaning_up, do: "Cleaning up…", else: "Clean up"}
    </button>
    """
  end

  attr :task, :any, required: true
  attr :roles_map, :map, required: true
  attr :round_questions, :list, required: true
  attr :suggestions, :map, required: true
  attr :conversation_run, :any, required: true
  attr :current_scope, Scope, required: true

  # Questions sit above the conversation they came out of. Answering only records:
  # the round reaches the agent when the human says it is done.
  defp conversation_sidebar(assigns) do
    ~H"""
    <.live_component
      :if={@round_questions != []}
      module={QuestionCard}
      id={"question-card-#{@conversation_run.id}"}
      questions={@round_questions}
      suggestions={@suggestions}
      run={@conversation_run}
      role_name={@roles_map[@conversation_run.role_id].name}
      current_scope={@current_scope}
    />

    <.live_component
      module={RunConversation}
      id="run-conversation"
      task={@task}
      runs={@task.runs || []}
      stage_run={@conversation_run}
      roles_map={@roles_map}
      current_scope={@current_scope}
    />
    """
  end

  # Whatever the open stage shows is read off disk or the rows again.
  defp reload_stage(socket) do
    case socket.assigns do
      %{pane: :plan, task: task, selected_role: role} ->
        send_update(PlanStage, id: stage_component_id(role), task: task)

      %{pane: :engineer, task: task, selected_role: role} ->
        send_update(EngineerStage, id: stage_component_id(role), task: task)

      %{pane: :review, task: task, selected_role: role} ->
        send_update(ReviewStage, id: stage_component_id(role), task: task)

      %{pane: :qa, task: task, selected_role: role} ->
        send_update(QaStage, id: stage_component_id(role), task: task)

      %{pane: :demo, task: task, selected_role: role} ->
        send_update(DemoStage, id: stage_component_id(role), task: task)

      _no_stage_on_disk ->
        :ok
    end
  end

  defp refresh_diff(%{assigns: %{pane: :engineer, selected_role: %Role{} = role, task: %Task{} = task}} = socket) do
    now = System.monotonic_time(:millisecond)

    if due?(socket.assigns.diff_refreshed_at, now) do
      send_update(EngineerStage, id: stage_component_id(role), task: task)
      assign(socket, :diff_refreshed_at, now)
    else
      socket
    end
  end

  defp refresh_diff(socket), do: socket

  defp due?(nil, _now), do: true
  defp due?(last, now), do: now - last >= @diff_refresh_ms

  # A task in a project the user cannot access reads the same as one that is gone.
  defp refresh_task(socket) do
    with {:ok, task} <- Pipeline.get_task(socket.assigns.url_id),
         true <- Scope.can_access_project?(socket.assigns.current_scope, task.project_id) do
      show_task(socket, task)
    else
      _missing -> assign(socket, :task, nil)
    end
  end

  # Every link to a child, its own included, lands on its parent's page with it selected.
  defp show_task(socket, %Task{parent_task_id: parent_id, issue: issue}) when is_binary(parent_id) do
    params = [child: issue.identifier, tab: socket.assigns.url_tab, file: socket.assigns.focus_file]
    params = Enum.reject(params, fn {_key, value} -> is_nil(value) end)
    push_patch(socket, to: ~p"/tasks/#{parent_id}?#{params}")
  end

  defp show_task(socket, %Task{} = task) do
    children =
      Pipeline.list_tasks(
        parent_task_id: task.id,
        include_cleaned_up: true,
        preload: [:project, :issue, runs: [:role, :questions]]
      )

    shown = Enum.find(children, task, &(&1.issue.identifier == socket.assigns.child))

    socket
    |> assign(:parent, if(children != [], do: Map.put(task, :children, children)))
    |> assign(:statuses, Enum.map(children, &child_status(&1, children)))
    |> assign(:task_id, shown.id)
    |> watch_family(task, children)
    |> load_assignees(shown)
    |> apply_task(shown)
    |> watch_diff_comments(shown)
    |> watch_outputs(shown)
    |> sync_tab_url()
  end

  # A split's parent hears every child's stage and issue, and a child hears its siblings'.
  defp watch_family(socket, %Task{} = parent, children) do
    if connected?(socket) and children != [] and not socket.assigns.watching_issues do
      Phoenix.PubSub.subscribe(Rail.PubSub, "issues")
    end

    socket
    |> assign(:family_ids, MapSet.new([parent | children], & &1.id))
    |> assign(:family_issue_ids, MapSet.new(children, & &1.issue_id))
    |> assign(:watching_issues, socket.assigns.watching_issues or (connected?(socket) and children != []))
  end

  # The owner menu offers only people who can open the task, read once per project rather than per refresh.
  defp load_assignees(%{assigns: %{task: %Task{project_id: project_id}}} = socket, %Task{project_id: project_id}),
    do: socket

  defp load_assignees(socket, %Task{} = task),
    do: assign(socket, :assignees, Users.list_linear_users(project_id: task.project_id))

  defp apply_task(socket, %Task{} = task) do
    roles = if task.project_id, do: Rail.Roles.list_roles(task.project_id), else: []
    started = started_roles(roles, task)
    {role, selected_run, children?} = selected(socket, started, task)

    asked = Pipeline.list_questions(task, order_by: [asc: :inserted_at, asc: :id])
    questions = Enum.filter(asked, &(&1.status == :pending))
    round_questions = round_questions(asked, selected_run)

    socket
    |> assign(:task, task)
    |> assign(:page_title, task.issue.title)
    |> assign(:roles_map, Map.new(roles, &{&1.id, &1}))
    |> assign(:selected_tab, tab_id(children?, role))
    |> assign(:tab_stage, task.stage)
    |> assign(:selected_role, role)
    |> assign(:selected_run, selected_run)
    |> assign(:stage_run, stage_run(started, task))
    |> assign(:line, line(stage_run(started, task)))
    |> assign(:conversation_run, selected_run)
    |> assign(:pane, if(children?, do: :children, else: pane(role)))
    |> assign(:approvable, approvable?(role, task, selected_run))
    |> assign(
      :tabs,
      family_tabs(
        build_tabs(task, started, role, questions),
        task,
        socket.assigns.parent,
        socket.assigns.statuses,
        children?
      )
    )
    |> assign_family(task)
    |> assign(:engineer_tab, engineer_tab(started))
    |> assign(:subscribed_run_ids, sync_run_subscriptions(socket, task.runs))
    |> assign(:watched_browser_task_id, watch_browser(socket, task, role, selected_run))
    |> assign(:round_questions, round_questions)
    |> assign(:suggestions, suggestions(round_questions))
    |> load_issue(task)
  end

  # The past answer each of the round's questions was matched to, read in one query.
  defp suggestions(round_questions) do
    case for(%{suggested_learning_id: id} <- round_questions, is_binary(id), do: id) do
      [] ->
        %{}

      ids ->
        {:ok, rules} = Learnings.list_learnings(ids: Enum.uniq(ids), sources: true)
        rules = Map.new(rules, &{&1.id, &1})

        # The answer is the gate's; who gave it, where and when are the rule's latest answer's.
        for %{suggested_learning_id: id} = question <- round_questions,
            rule = rules[id],
            source = Enum.find(rule.observations, &(&1.source_kind == :answer)),
            into: %{} do
          {question.id,
           %{
             answer: Learning.calculate_answer(rule, rule.observations),
             by: Observation.actor_label(source),
             identifier: source.task && source.task.issue.identifier,
             task_id: source.task_id,
             date: source.inserted_at
           }}
        end
    end
  end

  # The issue is a tab of its own and costs a query of its own, so it is read
  # only while it is the one being looked at.
  defp load_issue(socket, %Task{} = task) do
    preload = [:project, :owner_user, task: [runs: :role], comments: [:author_user, replies: :author_user]]

    case socket.assigns.pane do
      :issue -> assign(socket, :issue, read_issue(task.issue_id, preload))
      _other_tab -> assign(socket, :issue, nil)
    end
  end

  defp read_issue(issue_id, preload) do
    {:ok, issue} = Issues.get_issue(issue_id, preload: preload)
    issue
  end

  # A role with no run has nothing to read, so it is not a tab yet, unless its
  # stage is where the task is: demo is entered without starting, and its tab is
  # where the human decides whether it runs at all.
  defp selected(socket, started, %Task{} = task) do
    tab = socket.assigns.selected_tab
    # Moving between a parent and its children is a new task on the page, not one that moved stage.
    tab_stage = if match?(%Task{id: id} when id == task.id, socket.assigns.task), do: socket.assigns.tab_stage

    if children_tab?(socket.assigns.parent, task, tab, tab_stage, socket.assigns.url_tab) do
      {nil, nil, true}
    else
      {role, run} = select_tab(started, task, tab, tab_stage)
      {role, run, false}
    end
  end

  defp tab_id(true, _role), do: @children_tab
  defp tab_id(false, %Role{id: id}), do: id
  defp tab_id(false, nil), do: @issue_tab

  # A split parent opens on its board, and comes to it when approval splits it.
  defp children_tab?(%Task{id: id}, %Task{id: id} = task, tab, tab_stage, url_tab) do
    tab == @children_tab or (tab == nil and url_tab == nil) or (tab_stage != nil and tab_stage != task.stage)
  end

  defp children_tab?(_parent, _task, _tab, _tab_stage, _url_tab), do: false

  # A child never runs Plan, but its Plan tab is where its approved part is read.
  defp started_roles(roles, %Task{runs: runs, stage: stage} = task) do
    roles
    |> Enum.map(&{&1, role_run(runs, &1)})
    |> Enum.reject(fn {role, run} ->
      run == nil and not (role.stage == :demo and stage == :demo) and
        not (role.stage == :plan and is_binary(task.parent_task_id))
    end)
  end

  # The tab in the URL is the one to open. Without one, it is the role for the
  # stage the task sits at; and once the task moves on, that role takes over from
  # whatever the human was reading.
  defp select_tab(started, %Task{} = task, tab, tab_stage) do
    stage_entry = Enum.find(started, fn {role, _run} -> role.stage == task.stage end)
    picked = Enum.find(started, fn {role, _run} -> role.id == tab end)
    default = stage_entry || List.last(started)

    cond do
      tab_stage != nil and tab_stage != task.stage and stage_entry != nil -> stage_entry
      tab == @issue_tab -> {nil, nil}
      picked != nil -> picked
      default != nil -> default
      true -> {nil, nil}
    end
  end

  # Nothing is approved while its run is still working on it.
  defp approvable?(%Role{stage: stage}, %Task{stage: stage}, %Run{} = run), do: not Run.running?(run)
  defp approvable?(_role, _task, _run), do: false

  # The header says where the task is, whichever tab is open: a stage with no run
  # yet is queued, not whatever an earlier stage's run left behind.
  defp stage_run(started, %Task{stage: stage}) do
    Enum.find_value(started, fn {role, run} -> role.stage == stage and run end)
  end

  # What the stage's run waits on: its account's usage, or its place in the line for a sandbox.
  defp line(%Run{status: :waiting_for_usage} = run) do
    case Tools.get_usage_wait(run) do
      {:ok, wait} -> wait
      {:error, :not_waiting} -> nil
    end
  end

  defp line(%Run{} = run) do
    with :waiting <- Run.state(run),
         {:ok, line} <- Tools.get_queue_position(run) do
      line
    else
      _not_in_line -> nil
    end
  end

  defp line(nil), do: nil

  # Once the URL names a tab it keeps naming the one that is open, so a refresh
  # comes back here even after the task has moved the page on. A URL that names
  # none is left alone: it already means "wherever the task is now".
  defp sync_tab_url(%{assigns: %{url_tab: url_tab, selected_tab: selected}} = socket) when url_tab in [nil, selected] do
    socket
  end

  defp sync_tab_url(%{assigns: %{selected_tab: tab}} = socket) do
    push_patch(socket, to: task_path(socket, tab))
  end

  # A finding names a file, and the diff that file changed in is the engineer's
  # tab, so review can only link there once the engineer has a tab to link to.
  defp engineer_tab(started) do
    Enum.find_value(started, fn {role, _run} -> role.stage == :engineer and role.id end)
  end

  defp pane(nil), do: :issue
  defp pane(%Role{stage: stage}) when stage in [:plan, :engineer, :review, :qa, :demo], do: stage
  defp pane(%Role{}), do: :none

  defp stage_component_id(%Role{id: id}), do: "stage-#{id}"

  # A role is read through its latest run: an earlier one is the same conversation
  # before the stage sent the work back.
  defp role_run(runs, %Role{id: role_id}) do
    runs
    |> Enum.filter(&(&1.role_id == role_id))
    |> Enum.max_by(&(&1.started_at || &1.inserted_at), DateTime, fn -> nil end)
  end

  defp build_tabs(%Task{} = task, started, selected, questions) do
    counts = Enum.frequencies_by(questions, & &1.run_id)

    issue_tab = %{
      id: @issue_tab,
      stage: nil,
      label: "Linear Issue",
      sublabel: task.issue.identifier,
      tone: :issue,
      badge: 0,
      selected?: selected == nil
    }

    role_tabs =
      Enum.map(started, fn {role, run} ->
        %{
          id: role.id,
          stage: role.stage,
          label: role.name,
          sublabel: role_status_label(role, run, task),
          tone: tab_tone(run),
          badge: Map.get(counts, run && run.id, 0),
          selected?: selected != nil and selected.id == role.id
        }
      end)

    [issue_tab | role_tabs]
  end

  # The Children tab comes right after Plan, on the parent and on every child.
  defp family_tabs(tabs, _task, nil, _statuses, _children?), do: tabs

  defp family_tabs(tabs, %Task{} = task, %Task{} = parent, statuses, children?) do
    count = length(statuses)
    merged = Enum.count(statuses, &(&1.state == :merged))
    waiting = Enum.count(statuses, & &1.needs_attention)

    children_tab = %{
      id: @children_tab,
      stage: nil,
      label: "Children",
      sublabel: "#{merged} of #{count} merged",
      tone:
        cond do
          waiting > 0 -> :blocked
          merged == count -> :done
          Enum.any?(statuses, &(&1.state == :running)) -> :running
          true -> :idle
        end,
      badge: waiting,
      selected?: children?
    }

    plan_sublabel =
      if task.id == parent.id,
        do: "approved, split into #{count}",
        else: "approved in #{parent.issue.identifier}"

    tabs =
      Enum.map(tabs, fn
        %{stage: :plan} = tab -> %{tab | sublabel: plan_sublabel, tone: :done}
        %{id: @issue_tab} = tab -> %{tab | selected?: tab.selected? and not children?}
        tab -> tab
      end)

    plan_at = Enum.find_index(tabs, &(&1.stage == :plan)) || 0

    List.insert_at(tabs, plan_at + 1, children_tab)
  end

  # Where a split parent or a child of one stands, said in the header in place of a stage.
  defp assign_family(%{assigns: %{parent: nil}} = socket, %Task{} = task) do
    socket
    |> assign(:cleanup_confirm, cleanup_confirm(task.issue, []))
    |> assign(:show_switcher, false)
    |> assign(:header_status, nil)
    |> assign(:child_of, nil)
    |> assign(:split_points, nil)
  end

  defp assign_family(%{assigns: %{parent: %Task{id: id} = parent, statuses: statuses}} = socket, %Task{id: id}) do
    waiting = Enum.count(statuses, & &1.needs_attention)
    points = statuses |> Enum.map(&(&1.task.issue.estimate || 0)) |> Enum.sum()

    status =
      cond do
        waiting > 0 and viewer_owns?(socket, parent) ->
          %{
            label: "#{waiting} #{if waiting == 1, do: "child needs", else: "children need"} you",
            icon: "pi-arrows-split",
            class: "text-amber-700 dark:text-amber-300"
          }

        waiting > 0 ->
          %{
            label: "#{waiting} #{if waiting == 1, do: "child needs", else: "children need"} attention",
            icon: "pi-arrows-split",
            class: "text-slate-500 dark:text-slate-400"
          }

        parent.stage == :merged ->
          %{label: "Merged", icon: "pi-git-merge-fill", class: "text-emerald-600 dark:text-emerald-400"}

        true ->
          %{label: "Plan approved", icon: "pi-arrows-split", class: "text-slate-500 dark:text-slate-400"}
      end

    socket
    |> assign(:cleanup_confirm, cleanup_confirm(parent.issue, Enum.map(statuses, & &1.task.issue)))
    |> assign(:show_switcher, false)
    |> assign(:header_status, status)
    |> assign(:child_of, nil)
    |> assign(:split_points, if(points > 0, do: "#{points} #{if points == 1, do: "point", else: "points"}"))
  end

  defp assign_family(%{assigns: %{parent: %Task{} = parent, statuses: statuses}} = socket, %Task{id: id}) do
    status = Enum.find(statuses, &(&1.task.id == id))

    header_status =
      if status.state in [:waiting_on, :blocked_by_canceled],
        do: %{label: status.label, icon: status.icon, class: status.text_class}

    socket
    |> assign(:cleanup_confirm, nil)
    |> assign(:viewer_owns, viewer_owns?(socket, parent))
    |> assign(:show_switcher, true)
    |> assign(:header_status, header_status)
    |> assign(:child_of, %{
      parent: parent,
      position: status.task.split_position,
      total: length(statuses),
      waiting_on: status.waiting_on
    })
    |> assign(:split_points, nil)
  end

  # "You" is said only to the split's owner, which every child shares.
  defp viewer_owns?(socket, %Task{issue: issue}), do: issue.owner_user_id == socket.assigns.current_scope.user.id

  # Cleaning up work Linear has not marked done is usually a mistake, so the confirmation says so.
  defp cleanup_confirm(%Issue{state: :done}, []),
    do: "Clean up this task? Its worktree and scratch files will be deleted."

  defp cleanup_confirm(%Issue{identifier: identifier}, []) do
    "#{identifier} is not marked done in Linear. Clean up this task anyway? Its worktree and scratch files will be deleted."
  end

  defp cleanup_confirm(%Issue{}, children) do
    case Enum.reject(children, &(&1.state == :done)) do
      [] ->
        "Clean up this task and its #{length(children)} children? Their worktrees and scratch files will be deleted."

      open ->
        "#{length(open)} of #{length(children)} children are not marked done in Linear: " <>
          "#{Enum.map_join(open, ", ", & &1.identifier)}. Clean up this task and all of its children anyway? " <>
          "Their worktrees and scratch files will be deleted."
    end
  end

  # A child's tabs are its parent's page, so the child goes in the URL with the tab.
  defp task_path(%{assigns: %{parent: %Task{id: parent_id}, task: %Task{id: id} = task}}, tab) when parent_id != id do
    ~p"/tasks/#{parent_id}?child=#{task.issue.identifier}&tab=#{tab}"
  end

  defp task_path(%{assigns: %{url_id: url_id}}, tab), do: ~p"/tasks/#{url_id}?tab=#{tab}"

  # A run waiting for usage reads apart from one waiting for a sandbox.
  defp tab_tone(%Run{status: :waiting_for_usage}), do: :waiting_for_usage
  defp tab_tone(run), do: Run.state(run)

  # A run can ask several things at once, so its whole unsent round shows as tabs, in
  # the order they were asked. A run resumed without an answer still shows them.
  defp round_questions(asked, %Run{id: run_id}) do
    Enum.filter(
      asked,
      &(&1.run_id == run_id and &1.delivered_at == nil and &1.status in [:pending, :answered, :dismissed])
    )
  end

  defp round_questions(_asked, nil), do: []

  # `run:<id>` carries the run's log lines and the finish of its OS process. A
  # LiveComponent cannot subscribe, so the page holds this and forwards. Every run
  # on the task is followed, not just the one being read: the conversation can be
  # reading any of them, so the lines are tagged with their run on the way in.
  defp sync_run_subscriptions(socket, runs) do
    previous = socket.assigns.subscribed_run_ids
    current = MapSet.new(runs || [], & &1.id)

    if connected?(socket) do
      for id <- MapSet.difference(previous, current), do: Phoenix.PubSub.unsubscribe(Rail.PubSub, "run:#{id}")
      for id <- MapSet.difference(current, previous), do: Phoenix.PubSub.subscribe(Rail.PubSub, "run:#{id}")
    end

    current
  end

  # One topic per task, carrying whatever its browser is painting, heard only while
  # the panel can show it: on the QA or demo tab, with its run running. A finished
  # pass leaves its tab open until the task moves on, and a page that keeps
  # repainting would otherwise send every viewer frames nobody sees, which every
  # click on the page waits behind. Being heard is also what keeps Chrome painting
  # them, so a tab nobody can see costs nothing.
  defp watch_browser(socket, %Task{id: task_id}, role, run) do
    watched = socket.assigns.watched_browser_task_id
    wanted = if pane(role) in [:qa, :demo] and Run.running?(run), do: task_id

    if connected?(socket) and watched != wanted do
      if watched, do: Phoenix.PubSub.unsubscribe(Rail.PubSub, "browser:#{watched}")
      if wanted, do: Phoenix.PubSub.subscribe(Rail.PubSub, "browser:#{wanted}")
    end

    if connected?(socket), do: wanted, else: watched
  end

  # Sent and resolved comments are everyone's, so the task has a topic; unsent ones
  # are the reader's alone, so every tab of theirs also hears their own topic.
  defp watch_diff_comments(socket, %Task{id: task_id}) do
    watched = socket.assigns.watched_comments_task_id
    user_id = socket.assigns.current_scope.user.id

    if connected?(socket) and watched != task_id do
      if watched, do: Phoenix.PubSub.unsubscribe(Rail.PubSub, "diff_comments:#{watched}")
      if watched, do: Phoenix.PubSub.unsubscribe(Rail.PubSub, "diff_comments:#{watched}:#{user_id}")
      Phoenix.PubSub.subscribe(Rail.PubSub, "diff_comments:#{task_id}")
      Phoenix.PubSub.subscribe(Rail.PubSub, "diff_comments:#{task_id}:#{user_id}")
    end

    assign(socket, :watched_comments_task_id, if(connected?(socket), do: task_id, else: watched))
  end

  # Every save an agent makes on the task, from any stage, so every tab open on
  # it shows the save without a reload.
  defp watch_outputs(socket, %Task{id: task_id}) do
    watched = socket.assigns.watched_outputs_task_id

    if connected?(socket) and watched != task_id do
      if watched, do: Phoenix.PubSub.unsubscribe(Rail.PubSub, "outputs:#{watched}")
      Phoenix.PubSub.subscribe(Rail.PubSub, "outputs:#{task_id}")
    end

    assign(socket, :watched_outputs_task_id, if(connected?(socket), do: task_id, else: watched))
  end

  defp push_frame(socket, data) do
    Process.send_after(self(), :frame_window_closed, @frame_interval_ms)

    socket
    |> assign(:frame_window_open?, true)
    |> push_event("browser:frame", %{data: data})
  end

  defp claim_error(:already_assigned), do: "Somebody else claimed this issue first"
  defp claim_error(:linear_not_linked), do: "Link your Linear account in Settings before claiming an issue"

  defp update_branch_error(:task_busy), do: "Stop the task's run before updating its branch"
  defp update_branch_error(:uncommitted_changes), do: "Commit the engineer's work before updating the branch"
  defp update_branch_error(:no_worktree), do: "The task's worktree is gone, so there is nothing to update"
  defp update_branch_error(reason) when is_binary(reason), do: "Could not update the branch: #{reason}"
  defp update_branch_error(reason), do: "Could not update the branch: #{inspect(reason)}"
end
