defmodule RailWeb.TaskLive do
  @moduledoc """
  One task on one page: a header with every decision a person makes on it, a rail of the task's items, and the
  item picked beside it. The items are the issue, the plan with the conversation beside it and, once there is
  something of each to read, the findings, the next round's plan, the diff, the screens, the demo and the browser; a split adds its
  children. The item, the agent the conversation reads and a split's child are in the URL, so a refresh comes
  back to them.

  The conversation takes messages for Plan until its plan is approved, then for the review agent; every other
  agent's run is read there as the record of what it did.

  The page owns what the components cannot: the subscriptions. A LiveComponent may not subscribe, so log lines
  arrive here and are forwarded to the conversation, and a saved output to the open item, with `send_update/2`.
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
  alias Rail.Pipeline.Schemas.Round
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Roles.Schemas.Role
  alias Rail.Scope
  alias Rail.Tools
  alias Rail.Users
  alias RailWeb.Live.DiffView
  alias RailWeb.Live.PlanStage
  alias RailWeb.Live.RunConversation
  alias RailWeb.Live.TaskActions
  alias RailWeb.Live.TaskDetail

  # The engineer writes files as it works and the pane reads them off disk, so a
  # reader watching a run wants the diff to keep up. Re-reading on every batch of
  # log lines would shell out to git several times a second, so it is throttled to
  # this; the turn finishing re-reads regardless of when the last one was.
  @diff_refresh_ms 5_000

  # A full-size frame is a few hundred KB, so four a second is still a live
  # picture but a load any viewer's connection can keep up with.
  @frame_interval_ms 250

  # The items the URL can name; any other opens what the task is waiting on.
  @items ["issue", "plan", "children", "findings", "fix_plan", "diff", "screens", "demo", "browser"]

  # The agents whose runs the conversation reads, in the order a task meets them.
  @agents [:plan, :engineer, :qa, :review, :demo, :review_lead]

  # What the Issue tab's owner menu and comments raise, handled as the issue page handles them.
  @issue_events ["assign", "filter_assignees", "draft_comment", "comment"]

  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:task, nil)
      |> assign(:task_id, nil)
      |> assign(:page_title, "Task")
      |> assign(:current_section, :tasks)
      |> assign(:item, nil)
      |> assign(:agent, nil)
      |> assign(:round, nil)
      |> assign(:plan_run, nil)
      |> assign(:rounds, [])
      |> assign(:review_run, nil)
      |> assign(:chat_run, nil)
      |> assign(:chat_questions, 0)
      |> assign(:agents, [])
      |> assign(:stage_run, nil)
      |> assign(:line, nil)
      |> assign(:conversation_run, nil)
      |> assign(:diff_refreshed_at, nil)
      |> assign(:approvable, false)
      |> assign(:issue, nil)
      |> assign(:assignees, [])
      |> assign(:assignee_query, "")
      |> assign(:comment_nonce, 0)
      |> assign(:subscribed_run_ids, MapSet.new())
      |> assign(:watched_browser, nil)
      |> assign(:review_browser, nil)
      |> assign(:watched_comments_task_id, nil)
      |> assign(:watched_outputs_task_id, nil)
      |> assign(:frame_window_open?, false)
      |> assign(:held_frame, nil)
      |> assign(:awaited_frame, nil)
      |> assign(:roles_map, %{})
      |> assign(:round_questions, [])
      |> assign(:conversation_questions, [])
      |> assign(:suggestions, %{})
      |> assign(:cleaning_up, false)
      |> assign(:discard_open, false)
      |> assign(:discarding, false)
      |> assign(:discard_error, nil)
      |> assign(:discard_choice, :discard)
      |> assign(:discard_had_runs, false)
      |> assign(:discard_stopped, false)
      |> assign(:focus_file, nil)
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
      |> assign(:show_discard, false)
      |> assign(:show_back_to_plan, false)
      |> assign(:viewer_owns, false)

    # A stage moved from another page or by a run finishing is what keeps this one current.
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline")
      # The header names the workflow, which its file renames.
      Phoenix.PubSub.subscribe(Rail.PubSub, "workflows")
    end

    {:ok, socket}
  end

  def handle_params(%{"id" => task_id} = params, _uri, socket) do
    url = %{url_id: task_id, child: params["child"], focus_file: params["file"]}

    # The stage naming its item, or the conversation its agent, reads nothing again. A stale item is safe: the
    # stage reads it only on mount or a new task.
    socket =
      if socket.assigns.task != nil and Map.take(socket.assigns, Map.keys(url)) == url do
        socket
        |> assign(:item, params["item"])
        |> assign(:agent, params["agent"])
        |> assign(:round, params["round"])
        |> apply_task(socket.assigns.task)
      else
        socket
        |> assign(:url_id, task_id)
        |> assign(:task_id, task_id)
        |> assign(:child, params["child"])
        |> assign(:item, params["item"])
        |> assign(:agent, params["agent"])
        |> assign(:round, params["round"])
        |> assign(:focus_file, params["file"])
        |> refresh_task()
      end

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
            This task was discarded or its issue was deleted.
          </p>
        </div>

        <.live_component
          :if={@task != nil}
          module={TaskDetail}
          id="task-detail"
          task={@task}
          run={@review_run}
          stage_run={@stage_run}
          line={@line}
          status={@header_status}
          approvable={@approvable}
          questions={@chat_questions}
          split={@parent != nil}
          split_parent={@parent != nil and @parent.id == @task.id}
          current_scope={@current_scope}
          url_item={@item}
          url_round={@round}
          url_file={@focus_file}
        >
          <:breadcrumb :if={@show_switcher}>
            <.child_switcher
              statuses={@statuses}
              current_id={@task.id}
              parent={@parent}
              viewer_owns={@viewer_owns}
            />
          </:breadcrumb>
          <:actions>
            <span
              :if={@split_points}
              id="split-points"
              class="text-sm text-slate-500 dark:text-slate-400"
            >
              {@split_points}
            </span>
            <.claim_button task={@task} />
            <.discard_button :if={@show_discard} />
            <.cleanup_button task={@task} cleaning_up={@cleaning_up} confirm={@cleanup_confirm} />
            <.live_component
              module={TaskActions}
              id="task-actions"
              task={@task}
              rounds={@rounds}
              current_scope={@current_scope}
            />
          </:actions>
          <:issue>
            <.issue_view
              :if={@issue != nil}
              issue={@issue}
              assignees={@assignees}
              assignee_query={@assignee_query}
              comment_nonce={@comment_nonce}
              show_task={false}
              owner_editable={@task.parent_task_id == nil}
            />
          </:issue>
          <:plan>
            <.live_component
              module={PlanStage}
              id="plan-stage"
              current_scope={@current_scope}
              task={@task}
              run={@plan_run}
              chat_run={@chat_run}
              stage_run={@stage_run}
              line={@line}
              approvable={@task.stage == :plan and not Run.running?(@plan_run)}
              status={@header_status}
              child_of={@child_of}
            />
          </:plan>
          <:conversation>
            <.agent_picker
              :if={@open_item in [:plan, :fix_plan]}
              agents={@agents}
              picked={@conversation_run}
              chat_run={@chat_run}
            />
            <.conversation_sidebar
              compact={@open_item not in [:plan, :fix_plan]}
              task={@task}
              current_scope={@current_scope}
              roles_map={@roles_map}
              questions={@conversation_questions}
              round_questions={@round_questions}
              suggestions={@suggestions}
              conversation_run={
                if @open_item in [:plan, :fix_plan], do: @conversation_run, else: @chat_run
              }
              closed={
                @open_item in [:plan, :fix_plan] and @conversation_run != nil and
                  @conversation_run != @chat_run
              }
              closed_reason="Only Plan, and then the review agent, take messages. This is a record of what this agent did."
              review_pane={
                match?(
                  %Run{role: %Role{stage: :review_lead}},
                  if(@open_item in [:plan, :fix_plan], do: @conversation_run, else: @chat_run)
                )
              }
            />
          </:conversation>
          <:children>
            <.split_board :if={@parent} statuses={@statuses} parent_id={@parent.id} />
          </:children>
        </.live_component>
      </div>
    </Layouts.app>

    <.discard_dialog
      :if={@discard_open and @task != nil}
      task={@task}
      discarding={@discarding}
      error={@discard_error}
      stopped={@discard_stopped}
      choice={@discard_choice}
      back_to_plan={@show_back_to_plan}
    />
    """
  end

  def handle_event(event, params, socket) when event in @issue_events do
    {:noreply, handle_issue_event(event, params, socket, &refresh_task/1)}
  end

  # The Plan item's conversation reads any agent's run; only the one taking messages has a composer.
  def handle_event("pick_agent", %{"stage" => stage}, socket) do
    {:noreply, push_patch(socket, to: task_path(socket, item: "plan", agent: stage))}
  end

  def handle_event("cleanup", _params, socket) do
    task = socket.assigns.task

    socket =
      socket
      |> assign(:cleaning_up, true)
      |> start_async(:cleanup, fn -> Pipeline.cleanup_task(task) end)

    {:noreply, socket}
  end

  def handle_event("open_discard", _params, socket) do
    socket =
      socket
      |> assign(:discard_open, true)
      |> assign(:discard_error, nil)
      |> assign(:discard_stopped, false)
      |> assign(:discard_choice, :discard)

    {:noreply, socket}
  end

  def handle_event("pick_discard", _params, %{assigns: %{discarding: true}} = socket), do: {:noreply, socket}

  def handle_event("pick_discard", %{"choice" => "plan"}, %{assigns: %{show_back_to_plan: true}} = socket),
    do: {:noreply, pick(socket, :plan)}

  def handle_event("pick_discard", _params, socket), do: {:noreply, pick(socket, :discard)}

  # The dialog stays until the action under way has its answer, which opens the issue or the plan, or says what failed.
  def handle_event("close_discard", _params, %{assigns: %{discarding: true}} = socket), do: {:noreply, socket}

  def handle_event("close_discard", _params, socket) do
    socket =
      socket
      |> assign(:discard_open, false)
      |> assign(:discard_error, nil)

    {:noreply, socket}
  end

  def handle_event("discard", _params, %{assigns: %{discarding: true}} = socket), do: {:noreply, socket}

  def handle_event("discard", _params, socket) do
    %{current_scope: scope, task: task, discard_choice: choice} = socket.assigns

    # What the dialog listed as in progress is what "Runs stopped" stands for after a failure past the stops.
    socket =
      socket
      |> assign(:discarding, true)
      |> assign(:discard_error, nil)
      |> assign(:discard_had_runs, Enum.any?(task.runs, &(Run.running?(&1) or Run.state(&1) == :blocked)))
      |> start_async(:discard, fn ->
        # Unlinked, so leaving the page does not cut Back to Plan off between its commit and the Planner's start.
        action = Elixir.Task.Supervisor.async_nolink(Rail.TaskSupervisor, fn -> act(choice, scope, task) end)
        {choice, Elixir.Task.await(action, :infinity)}
      end)

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

  def handle_info({:run_events, run_id, events}, socket) do
    for {run_id, batches} <- Enum.group_by(queued_run_events([{run_id, events}]), &elem(&1, 0), &elem(&1, 1)),
        MapSet.member?(socket.assigns.subscribed_run_ids, run_id) do
      send_update(RunConversation, id: "run-conversation", run_id: run_id, appended_events: Enum.concat(batches))
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
  # it closes, and the rest are dropped, since each one only replaces the last. A frame from a browser the
  # page has stopped watching, still in its mailbox, is dropped too.
  def handle_info({:browser_frame, task_id, name, data}, socket) do
    if socket.assigns.watched_browser == "browser:#{task_id}:#{name}",
      do: {:noreply, show_frame(socket, data)},
      else: {:noreply, socket}
  end

  # The demo recording is what reads the page's actions, and the page has no use for them.
  def handle_info({:browser_action, _task_id, _name, _kind}, socket), do: {:noreply, socket}

  def handle_info(:frame_window_closed, socket) do
    case socket.assigns.held_frame do
      data when is_binary(data) -> {:noreply, push_frame(assign(socket, :held_frame, nil), data)}
      nil -> {:noreply, assign(socket, :frame_window_open?, false)}
    end
  end

  # Comments the reader sees moved, in another tab or this one. Only the comments
  # are read again: the diff under them has not moved, and is drawn only while its item is open.
  def handle_info({:diff_comments_changed, task_id}, socket) do
    with %{open_item: :diff, task_id: ^task_id} <- socket.assigns do
      send_update(DiffView, id: "diff-view", reload_comments: true)
    end

    {:noreply, reload_review_comments(socket, task_id)}
  end

  # The reader's unsent screen comments moved: the Review stage marks its screens with them and the tray lists them.
  def handle_info({:screen_comments_changed, task_id}, socket) do
    {:noreply, reload_review_comments(socket, task_id)}
  end

  # The reader's unsent finding comments moved: the Review stage draws them under their pieces and the tray lists them.
  def handle_info({:finding_comments_changed, task_id}, socket) do
    {:noreply, reload_review_comments(socket, task_id)}
  end

  # What Review's Send would send of the findings, and whether it can, for the conversation's tray.
  def handle_info({:review_tray, tray}, socket) do
    send_update(RunConversation, id: "run-conversation", review_tray: tray)
    {:noreply, socket}
  end

  # The tray, which only the review agent's conversation draws, opens a finding or a screen state.
  def handle_info({event, key}, socket) when event in [:open_review_finding, :open_review_screen] do
    opened = if event == :open_review_finding, do: [open_finding: key], else: [open_screen: key]
    send_update(TaskDetail, [id: "task-detail"] ++ opened)
    {:noreply, socket}
  end

  # The reader's unsent plan comments moved, in another tab or this one: the Plan stage, or the next round's plan,
  # draws their markers, the conversation their tray and the header whether Approve plan waits on them, and each
  # reads its own.
  def handle_info({:plan_comments_changed, task_id}, socket) do
    # The conversation is drawn under every item, as its trays at least, so it always reads them.
    with %{task_id: ^task_id, open_item: item} <- socket.assigns do
      if item == :plan, do: send_update(PlanStage, id: "plan-stage", reload_comments: true)
      if item == :fix_plan, do: send_update(TaskDetail, id: "task-detail", reload: true)
      send_update(RunConversation, id: "run-conversation", reload_plan_comments: true)
      send_update(TaskActions, id: "task-actions")
    end

    {:noreply, socket}
  end

  # The Plan stage found which of the reader's ticket and plan comments no longer have their line; the tray marks them.
  def handle_info({:plan_comments_lifted, ids}, socket) do
    send_update(RunConversation, id: "run-conversation", lifted_plan_comments: ids)
    {:noreply, socket}
  end

  # The Plan item opened another round, which the URL names in place for a reload, beside the same agent's run.
  def handle_info({:plan_round, round}, socket) do
    path = task_path(socket, item: "plan", round: round, agent: socket.assigns.agent)
    {:noreply, push_patch(socket, to: path, replace: true)}
  end

  # The stage opened another item, which the URL names in place for a reload; the Plan item keeps the agent its
  # conversation reads.
  def handle_info({:review_item, item}, socket) do
    agent = if item in [:plan, :fix_plan], do: socket.assigns.agent
    {:noreply, push_patch(socket, to: task_path(socket, item: Atom.to_string(item), agent: agent), replace: true)}
  end

  # Sent by the stage as it drew, so it can land after the task was discarded underneath the page.
  def handle_info({:watch_browser, _name}, %{assigns: %{task: nil}} = socket), do: {:noreply, socket}

  # The Browser item is open on this browser, or on none; only the subscription moves.
  def handle_info({:watch_browser, name}, socket) do
    socket = assign(socket, :review_browser, name)
    {:noreply, watch_browser(socket, socket.assigns.task, socket.assigns.open_item)}
  end

  # The browser the page shows closed, so the Review stage reads its browsers again and stops offering it.
  def handle_info({:browser_closed, task_id, name}, socket) do
    if socket.assigns.watched_browser == "browser:#{task_id}:#{name}", do: reload_stage(socket)
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

  # Only a task a workflow opened names one, so no other page reads its task again on a sync.
  def handle_info(
        {:workflows_changed, project_id},
        %{assigns: %{task: %Task{project_id: project_id, issue: %Issue{workflow_id: workflow_id}}}} = socket
      )
      when is_binary(workflow_id) do
    {:noreply, refresh_task(socket)}
  end

  def handle_info({:workflows_changed, _project_id}, socket), do: {:noreply, socket}

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

  # A tech lead approved the task's pull request, in this tab or another; the header says whose approval is in.
  def handle_info({:approvals_changed, task_id}, socket) do
    with %{task_id: ^task_id, task: %Task{}} <- socket.assigns do
      send_update(TaskActions, id: "task-actions", reload_approvals: true)
    end

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

  # A discarded task is gone, so the issue is where it can be started again.
  def handle_async(:discard, {:ok, {:discard, {:ok, %Task{issue_id: issue_id}}}}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/issues/#{issue_id}")}
  end

  # Navigated rather than patched, so every pane mounts again on the task as it now stands.
  def handle_async(:discard, {:ok, {:plan, {:ok, %Task{id: id}}}}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/tasks/#{id}?item=plan")}
  end

  def handle_async(:discard, {:ok, {choice, {:error, reason}}}, socket) do
    stopped = socket.assigns.discard_had_runs and after_stops?(reason)

    socket =
      socket
      |> assign(:discarding, false)
      |> assign(:discard_stopped, stopped)
      |> assign(:discard_error, discard_error(choice, reason, stopped))
      |> refresh_task()

    {:noreply, socket}
  end

  def handle_async(:discard, {:exit, _reason}, socket) do
    socket =
      socket
      |> assign(:discarding, false)
      |> assign(:discard_error, discard_error(socket.assigns.discard_choice, :crashed, false))
      |> assign(:discard_stopped, false)
      |> refresh_task()

    {:noreply, socket}
  end

  # A live frame that arrived first is newer than the one asked for, which is then dropped.
  def handle_async({:held_frame, topic}, {:ok, "" <> data}, %{assigns: %{awaited_frame: topic}} = socket),
    do: {:noreply, show_frame(socket, data)}

  def handle_async({:held_frame, _topic}, _none_or_stale, socket), do: {:noreply, socket}

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

  defp discard_button(assigns) do
    ~H"""
    <button
      type="button"
      id="discard-task"
      data-qa="discard_task"
      phx-click="open_discard"
      class="shrink-0 inline-flex items-center gap-1.5 px-4 py-2 rounded-lg border border-red-300 dark:border-red-800 text-sm font-semibold text-red-600 dark:text-red-400 hover:bg-red-50 dark:hover:bg-red-950 cursor-pointer focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500"
    >
      <.icon name="pi-trash-bold" class="size-[15px]" /> Discard
    </button>
    """
  end

  attr :agents, :list, required: true, doc: "each agent's latest run on the task, in the order a task meets them"
  attr :picked, :any, required: true
  attr :chat_run, :any, required: true

  # Every agent's run is read here; the one taking messages is marked.
  defp agent_picker(assigns) do
    ~H"""
    <nav
      :if={length(@agents) > 1}
      id="conversation-agents"
      aria-label="Agents"
      class="flex items-center gap-1 overflow-x-auto px-4 py-2 border-b border-slate-200 dark:border-slate-700"
    >
      <button
        :for={run <- @agents}
        type="button"
        id={"conversation-agent-#{run.role.stage}"}
        data-qa="conversation_agent"
        aria-current={to_string(@picked != nil and run.id == @picked.id)}
        phx-click="pick_agent"
        phx-value-stage={run.role.stage}
        class={[
          "shrink-0 inline-flex items-center gap-1.5 px-2.5 py-1 rounded-md text-xs font-semibold cursor-pointer",
          (@picked != nil and run.id == @picked.id) &&
            "bg-blue-50 dark:bg-blue-950/40 text-blue-800 dark:text-blue-200 ring-1 ring-blue-200 dark:ring-blue-800",
          (@picked == nil or run.id != @picked.id) &&
            "text-slate-600 dark:text-slate-300 hover:bg-slate-100 dark:hover:bg-slate-800/60"
        ]}
      >
        <span
          :if={Run.running?(run)}
          data-qa="conversation_agent_running"
          class="size-1.5 rounded-full bg-green-500 motion-safe:animate-pulse"
        />
        {run.role.name}
        <.icon :if={@chat_run != nil and run.id == @chat_run.id} name="pi-chat-text" class="size-3.5" />
      </button>
    </nav>
    """
  end

  attr :task, :any, required: true
  attr :roles_map, :map, required: true
  attr :questions, :list, required: true, doc: "every question the conversation's run asked"
  attr :round_questions, :list, required: true
  attr :suggestions, :map, required: true
  attr :conversation_run, :any, required: true
  attr :current_scope, Scope, required: true
  # Plan's conversation is read but closed once its plan is approved, so nothing can change what was approved,
  # and the engineer's once the task has left Engineer.
  attr :closed, :boolean, default: false
  attr :closed_reason, :string, default: "The plan is approved, so this conversation is closed."
  # Only the review agent's conversation draws the Review tray.
  attr :review_pane, :boolean, default: false
  # Under any other item, only the trays of comments waiting to be sent show.
  attr :compact, :boolean, default: false

  # An open round takes the composer's place in the conversation it came out of. Answering only records:
  # the round reaches the agent when the human says it is done.
  defp conversation_sidebar(assigns) do
    ~H"""
    <.live_component
      module={RunConversation}
      id="run-conversation"
      task={@task}
      runs={@task.runs || []}
      stage_run={@conversation_run}
      roles_map={@roles_map}
      current_scope={@current_scope}
      closed={@closed}
      closed_reason={@closed_reason}
      review_pane={@review_pane}
      compact={@compact}
      questions={@questions}
      round_questions={@round_questions}
      suggestions={@suggestions}
    />
    """
  end

  defp reload_review_comments(socket, task_id) do
    # The stage reads the task it already holds: one handed over here could be older than the page's next render.
    with %{task_id: ^task_id, task: %Task{}} <- socket.assigns do
      send_update(TaskDetail, id: "task-detail", reload: true)
      send_update(RunConversation, id: "run-conversation", reload_review_comments: true)
    end

    socket
  end

  # Whatever the open item shows is read off disk or the rows again.
  # A task cleaned up underneath the page has nothing on disk to read.
  defp reload_stage(socket) do
    with %{task: %Task{} = task, open_item: item} <- socket.assigns do
      send_update(TaskDetail, id: "task-detail", reload: true)
      if item == :plan, do: send_update(PlanStage, id: "plan-stage", task: task)
      if item == :diff, do: send_update(DiffView, id: "diff-view", reload: true)
    end

    :ok
  end

  defp refresh_diff(%{assigns: %{open_item: :diff, task: %Task{}}} = socket) do
    now = System.monotonic_time(:millisecond)

    if due?(socket.assigns.diff_refreshed_at, now) do
      send_update(DiffView, id: "diff-view", reload: true)
      assign(socket, :diff_refreshed_at, now)
    else
      socket
    end
  end

  defp refresh_diff(socket), do: socket

  # A run writing faster than the page reads has batches waiting behind this one.
  # They are read with it, so a click is never queued behind a redraw per batch.
  defp queued_run_events(batches) do
    receive do
      {:run_events, run_id, events} -> queued_run_events([{run_id, events} | batches])
    after
      0 -> Enum.reverse(batches)
    end
  end

  defp due?(nil, _now), do: true
  defp due?(last, now), do: now - last >= @diff_refresh_ms

  # A task in a project the user cannot access reads the same as one that is gone.
  defp refresh_task(socket) do
    with {:ok, task} <- Pipeline.get_task(socket.assigns.url_id),
         true <- Scope.can_access_project?(socket.assigns.current_scope, task.project_id) do
      socket
      |> show_task(task)
      |> follow_back_to_plan(socket.assigns.task, task)
    else
      _missing -> assign(socket, :task, nil)
    end
  end

  # The tab that sent the task back navigates from its own handle_async; leaving first would kill the action.
  defp follow_back_to_plan(%{assigns: %{discarding: true}} = socket, _was, _task), do: socket

  defp follow_back_to_plan(socket, %Task{id: id, stage: was}, %Task{id: id, stage: :plan})
       when was in [:engineer, :review, :finalize], do: push_navigate(socket, to: ~p"/tasks/#{id}?item=plan")

  defp follow_back_to_plan(socket, _was, _task), do: socket

  # Every link to a child, its own included, lands on its parent's page with it selected.
  defp show_task(socket, %Task{parent_task_id: parent_id, issue: issue}) when is_binary(parent_id) do
    params = [
      child: issue.identifier,
      item: socket.assigns.item,
      agent: socket.assigns.agent,
      round: socket.assigns.round,
      file: socket.assigns.focus_file
    ]

    params = Enum.reject(params, fn {_key, value} -> is_nil(value) end)
    push_patch(socket, to: ~p"/tasks/#{parent_id}?#{params}")
  end

  defp show_task(socket, %Task{} = task) do
    children =
      Pipeline.list_tasks(
        parent_task_id: task.id,
        include_cleaned_up: true,
        preload: [:project, :issue, :marked_ready_by, :merged_by, runs: [:role, :questions]]
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
    do:
      assign(socket, :assignees, Users.list_assignable_users(project_id: task.project_id, tracker: task.project.tracker))

  defp apply_task(socket, %Task{} = task) do
    roles = if task.project_id, do: Rail.Roles.list_roles(task.project_id), else: []
    runs = role_runs(roles, task)
    rounds = Pipeline.list_rounds(task)
    back_to_plan = discardable?(task) and task.stage != :plan and match?(%Round{plan: "" <> _plan}, List.first(rounds))

    socket
    |> assign(:task, task)
    |> assign(:page_title, task.issue.title)
    |> assign(:roles_map, Map.new(roles, &{&1.id, &1}))
    |> assign(:open_item, open_item(socket.assigns.item, task, socket.assigns.parent))
    |> assign(:rounds, rounds)
    |> assign_runs(runs, task)
    |> assign_questions(task)
    |> assign_family(task)
    |> assign(:show_discard, discardable?(task))
    |> assign(:show_back_to_plan, back_to_plan)
    |> assign(:discard_choice, if(back_to_plan, do: socket.assigns.discard_choice, else: :discard))
    |> assign(:subscribed_run_ids, sync_run_subscriptions(socket, task.runs))
    |> assign_watched_browser(task)
    |> load_issue(task)
  end

  # The run the conversation takes messages for, the one it reads (the URL's agent, or else that one), and the
  # run the header says the task is waiting on.
  defp assign_runs(socket, runs, %Task{} = task) do
    chat_run = if task.stage == :plan, do: runs[:plan], else: runs[:review_lead]
    picked = Enum.find_value(runs, fn {stage, run} -> to_string(stage) == socket.assigns.agent && run end)
    stage_run = stage_run(runs, task)

    socket
    |> assign(:plan_run, runs[:plan])
    |> assign(:review_run, runs[:review_lead])
    |> assign(:chat_run, chat_run)
    |> assign(:agents, for(stage <- @agents, %Run{} = run <- [runs[stage]], do: run))
    |> assign(:stage_run, stage_run)
    |> assign(:line, line(stage_run))
    |> assign(:conversation_run, picked || chat_run || runs |> Map.values() |> List.last())
    |> assign(:approvable, task.stage == :review and not Run.running?(runs[:review_lead]))
  end

  defp assign_questions(socket, %Task{} = task) do
    %{chat_run: chat_run, conversation_run: conversation_run} = socket.assigns
    asked = Pipeline.list_questions(task, order_by: [asc: :inserted_at, asc: :id])
    round_questions = round_questions(asked, conversation_run)

    socket
    |> assign(:chat_questions, Enum.count(asked, &((&1.status == :pending and chat_run) && &1.run_id == chat_run.id)))
    |> assign(:round_questions, round_questions)
    |> assign(:conversation_questions, run_questions(asked, conversation_run))
    |> assign(:suggestions, suggestions(round_questions))
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

  # The issue is an item of its own and costs a query of its own, so it is read
  # only while it is the one being looked at.
  defp load_issue(socket, %Task{} = task) do
    preload = [:project, :owner_user, task: [runs: :role], comments: [:author_user, replies: :author_user]]

    case socket.assigns.open_item do
      :issue -> assign(socket, :issue, read_issue(task.issue_id, preload))
      _other_item -> assign(socket, :issue, nil)
    end
  end

  defp read_issue(issue_id, preload) do
    {:ok, issue} = Issues.get_issue(issue_id, preload: preload)
    issue
  end

  # The item the stage opens: the URL's, or else what the task is waiting on now, as the stage reads it.
  defp open_item(nil, %Task{id: id}, %Task{id: id}), do: :children
  defp open_item(nil, %Task{stage: :plan}, _parent), do: :plan
  defp open_item(nil, %Task{stage: :engineer}, _parent), do: :diff
  defp open_item(nil, %Task{}, _parent), do: :findings
  # The conversation was an item of its own; it is the Plan item's sidebar now.
  defp open_item("conversation", %Task{}, _parent), do: :plan
  defp open_item(item, %Task{}, _parent) when item in @items, do: String.to_existing_atom(item)
  defp open_item(_unknown, %Task{} = task, parent), do: open_item(nil, task, parent)

  # Each role read through its latest run: an earlier one is the same conversation before the stage sent the work
  # back.
  defp role_runs(roles, %Task{runs: runs}) do
    for %Role{} = role <- roles, %Run{} = run <- [role_run(runs, role)], into: %{}, do: {role.stage, run}
  end

  # The header says where the task is: at Review, whichever agent is checking the round, else the review agent.
  defp stage_run(runs, %Task{stage: :review}) do
    Enum.find_value([:qa, :review, :demo], &(Run.running?(runs[&1]) && runs[&1])) || runs[:review_lead]
  end

  defp stage_run(runs, %Task{stage: stage}), do: runs[Task.role_stage(stage)]

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

  # A role is read through its latest run: an earlier one is the same conversation
  # before the stage sent the work back.
  defp role_run(runs, %Role{id: role_id}) do
    runs
    |> Enum.filter(&(&1.role_id == role_id))
    |> Enum.max_by(&(&1.started_at || &1.inserted_at), DateTime, fn -> nil end)
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
      total: split_total(statuses),
      waiting_on: status.waiting_on
    })
    |> assign(:split_points, nil)
  end

  # "You" is said only to the split's owner, which every child shares.
  defp viewer_owns?(socket, %Task{issue: issue}), do: issue.owner_user_id == socket.assigns.current_scope.user.id

  # A split is as big as it was approved, so a child deleted in Linear since does not shrink it.
  defp split_total(statuses), do: statuses |> Enum.map(& &1.task.split_position) |> Enum.max()

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

  # A child is shown on its parent's page, so the child goes in the URL with the item.
  defp task_path(socket, params) do
    {id, child} =
      case socket.assigns do
        %{parent: %Task{id: parent_id}, task: %Task{id: id, issue: issue}} when parent_id != id ->
          {parent_id, issue.identifier}

        %{url_id: url_id} ->
          {url_id, nil}
      end

    params = Enum.reject([child: child] ++ params, fn {_key, value} -> is_nil(value) end)
    ~p"/tasks/#{id}?#{params}"
  end

  # A run can ask several things at once, so its whole unsent round shows as tabs, in
  # the order they were asked. A run resumed without an answer still shows them.
  defp round_questions(asked, %Run{id: run_id}) do
    Enum.filter(
      asked,
      &(&1.run_id == run_id and &1.delivered_at == nil and &1.status in [:pending, :answered, :dismissed])
    )
  end

  defp round_questions(_asked, nil), do: []

  defp run_questions(asked, %Run{id: run_id}), do: Enum.filter(asked, &(&1.run_id == run_id))
  defp run_questions(_asked, nil), do: []

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

  defp assign_watched_browser(socket, %Task{} = task), do: watch_browser(socket, task, socket.assigns.open_item)

  # One topic per task and browser name, carrying whatever that browser is painting,
  # heard only while the panel can show it: the browser the Browser
  # item is open on. A round leaves its tabs open until the task leaves Review, and
  # a page that keeps repainting would otherwise send every viewer frames nobody
  # sees, which every click on the page waits behind. Being heard is also what keeps
  # Chrome painting them, so a tab nobody can see costs nothing.
  defp watch_browser(socket, %Task{id: task_id} = task, item) do
    watched = socket.assigns.watched_browser
    name = socket.assigns.review_browser
    wanted = if item == :browser and is_binary(name), do: "browser:#{task_id}:#{name}"

    if connected?(socket) and watched != wanted do
      if watched, do: Phoenix.PubSub.unsubscribe(Rail.PubSub, watched)
      if wanted, do: Phoenix.PubSub.subscribe(Rail.PubSub, wanted)
      socket = socket |> assign(:watched_browser, wanted) |> assign(:held_frame, nil)
      if wanted, do: show_held_frame(socket, task, name), else: assign(socket, :awaited_frame, nil)
    else
      socket
    end
  end

  # A browser on a still page paints nothing new for a new watcher, so the frame it holds is asked for, off
  # the page's process since a busy session can be slow to answer.
  defp show_held_frame(socket, %Task{} = task, name) do
    topic = "browser:#{task.id}:#{name}"

    socket
    |> assign(:awaited_frame, topic)
    |> start_async({:held_frame, topic}, fn -> Tools.get_browser_frame(task, name) end)
  end

  defp show_frame(socket, data) do
    socket = assign(socket, :awaited_frame, nil)
    if socket.assigns.frame_window_open?, do: assign(socket, :held_frame, data), else: push_frame(socket, data)
  end

  # Sent and resolved comments are everyone's, so the task has a topic; unsent ones
  # are the reader's alone, so every tab of theirs also hears their own topic. Plan,
  # screen and finding comments are only ever unsent on the page, so they have only the reader's topic.
  defp watch_diff_comments(socket, %Task{id: task_id}) do
    watched = socket.assigns.watched_comments_task_id
    user_id = socket.assigns.current_scope.user.id

    if connected?(socket) and watched != task_id do
      if watched, do: Phoenix.PubSub.unsubscribe(Rail.PubSub, "diff_comments:#{watched}")
      if watched, do: Phoenix.PubSub.unsubscribe(Rail.PubSub, "diff_comments:#{watched}:#{user_id}")
      if watched, do: Phoenix.PubSub.unsubscribe(Rail.PubSub, "plan_comments:#{watched}:#{user_id}")
      if watched, do: Phoenix.PubSub.unsubscribe(Rail.PubSub, "screen_comments:#{watched}:#{user_id}")
      if watched, do: Phoenix.PubSub.unsubscribe(Rail.PubSub, "finding_comments:#{watched}:#{user_id}")
      Phoenix.PubSub.subscribe(Rail.PubSub, "diff_comments:#{task_id}")
      Phoenix.PubSub.subscribe(Rail.PubSub, "diff_comments:#{task_id}:#{user_id}")
      Phoenix.PubSub.subscribe(Rail.PubSub, "plan_comments:#{task_id}:#{user_id}")
      Phoenix.PubSub.subscribe(Rail.PubSub, "screen_comments:#{task_id}:#{user_id}")
      Phoenix.PubSub.subscribe(Rail.PubSub, "finding_comments:#{task_id}:#{user_id}")
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

  # Mirrors what Discard itself refuses; a merge in progress is offered, so the dialog can say why it waits.
  defp discardable?(%Task{cleaned_up_at: nil, merged_at: nil, parent_task_id: nil, stage: stage}),
    do: stage not in [:merged, :split]

  defp discardable?(%Task{}), do: false

  defp act(:discard, scope, task), do: Pipeline.discard_task(scope, task)
  defp act(:plan, scope, task), do: Pipeline.return_to_plan(scope, task)

  # Only a failure past the stops leaves runs stopped: GitHub's refusals, and a run still settling.
  defp after_stops?({step, _reason}) when step in [:branch_not_deleted, :pull_request_not_closed], do: true
  defp after_stops?(:task_busy), do: true
  defp after_stops?(_reason), do: false

  defp pick(%{assigns: %{discard_choice: choice}} = socket, choice), do: socket

  # An error names the choice it came from, so it goes with that choice.
  defp pick(socket, choice) do
    socket
    |> assign(:discard_choice, choice)
    |> assign(:discard_error, nil)
    |> assign(:discard_stopped, false)
  end

  defp discard_error(:plan, :not_discardable, _stopped),
    do: "This task already went back to Plan, or was discarded or cleaned up."

  defp discard_error(:discard, :not_discardable, _stopped), do: "This task was already discarded or cleaned up."

  defp discard_error(choice, {:branch_not_deleted, "" <> reason}, stopped),
    do: "GitHub refused to delete the branch: #{reason}. " <> left_as_was(choice, stopped)

  defp discard_error(choice, {:branch_not_deleted, _reason}, stopped),
    do: "GitHub refused to delete the branch. " <> left_as_was(choice, stopped)

  defp discard_error(choice, {:pull_request_not_closed, _reason}, stopped),
    do: "GitHub refused to close the pull request. " <> left_as_was(choice, stopped)

  defp discard_error(choice, :task_busy, _stopped), do: "A run was still finishing. #{again(choice)} to stop it."

  defp discard_error(:plan, :merging, _stopped),
    do: "A merge is in progress. Take it back to Plan once it finishes or fails."

  defp discard_error(:discard, :merging, _stopped), do: "A merge is in progress. Discard once it finishes or fails."
  defp discard_error(:plan, _reason, _stopped), do: "Could not take the task back to Plan."
  defp discard_error(:discard, _reason, _stopped), do: "Could not discard the task."

  defp left_as_was(choice, true),
    do: "The runs are stopped; the worktree and ticket are as they were. #{again(choice)} to finish."

  defp left_as_was(choice, false), do: "The worktree and ticket are as they were. #{again(choice)} to finish."

  defp again(:plan), do: "Click Back to Plan again"
  defp again(:discard), do: "Discard again"

  defp claim_error(:already_assigned), do: "Somebody else claimed this issue first"
  defp claim_error(:linear_not_linked), do: "Link your Linear account in Settings before claiming an issue"
end
