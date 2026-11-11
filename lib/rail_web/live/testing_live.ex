defmodule RailWeb.TestingLive do
  @moduledoc false
  use RailWeb, :live_view

  import RailWeb.Utils.IssueRelative

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Scope

  @preload [
    :project,
    :owner_user,
    :workflow,
    :parent,
    :children,
    task: [:rounds, runs: :role, parent_task: [children: :issue]],
    comments: [:author_user, replies: :author_user]
  ]

  # The usual longest gap between a double click's two clicks, so the second lands on the loading screen.
  @advance_ms 500

  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Rail.PubSub, "issues")
      Phoenix.PubSub.subscribe(Rail.PubSub, "testing")
      Phoenix.PubSub.subscribe(Rail.PubSub, "cycles")
    end

    socket =
      socket
      |> assign(:page_title, "Testing")
      |> assign(:current_section, :testing)
      |> assign(:issue, nil)
      |> assign(:blockers, nil)
      |> assign(:cycles, nil)
      |> assign(:notice, nil)
      |> assign(:advancing, nil)
      |> assign(:notes_rev, 0)

    {:ok, socket}
  end

  # The open ticket is in the URL, so it can be linked to. A notice outlives only the patch its action made.
  def handle_params(params, _uri, socket) do
    notice = socket.assigns.notice

    socket =
      socket
      |> assign(:selected_id, params["id"])
      |> assign(:notice, if(notice && notice.for == params["id"], do: notice))
      |> assign(:advancing, nil)
      |> assign(:notes_rev, 0)
      |> load(:select)

    {:noreply, socket}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} {assigns}>
      <div id="testing-page" data-qa="testing-page" class="-m-6 h-[calc(100%+3rem)] flex min-h-0">
        <.testing_queue issues={@queue} selected_id={@issue && @issue.id} now={@now} />

        <section id="testing-ticket" class="flex-1 min-w-0 flex flex-col min-h-0">
          <div
            :if={@advancing}
            id="testing-advancing"
            class="flex-1 flex items-center justify-center gap-2 text-sm text-slate-500 dark:text-slate-400"
          >
            <.icon name="pi-circle-notch" class="size-4 motion-safe:animate-spin" />{@advancing.label}
          </div>

          <div
            :if={@issue && !@advancing}
            id="testing-bar"
            class="flex items-center gap-3 px-6 py-3 border-b border-slate-200 dark:border-slate-700 flex-wrap"
          >
            <span class="font-mono text-xs text-slate-500 dark:text-slate-400">{@issue.identifier}</span>
            <.testing_badge
              :if={@show_testing_state}
              id="testing-bar-state"
              state={@issue.testing_state}
            />
            <span
              :if={@issue.completed_at}
              class="inline-flex items-center gap-1 text-xs text-slate-500 dark:text-slate-400"
            >
              <.icon name="pi-check-circle-fill" class="size-3.5 text-indigo-400" />
              Done {format_age(DateTime.diff(@now, @issue.completed_at))} ago
            </span>
            <.link
              navigate={~p"/issues/#{@issue.identifier}"}
              id="testing-open-issue"
              class="inline-flex items-center gap-1 text-xs text-slate-500 dark:text-slate-400 hover:underline"
            >
              <.icon name="pi-arrow-square-out" class="size-3.5" />Open issue
            </.link>
            <div :if={@in_queue} class="ml-auto flex items-center gap-2">
              <.button
                id="testing-send-to-triage"
                phx-click="send_to_triage"
                phx-value-issue_id={@issue.id}
                phx-disable-with="Sending..."
                disabled={@notes_blank}
                title={if @notes_blank, do: "Write testing notes to send this to triage"}
              >
                <.icon name="pi-tray" class="size-4" />Send to triage
              </.button>
              <.button
                id="testing-mark-tested"
                variant="success"
                phx-click="mark_tested"
                phx-value-issue_id={@issue.id}
                phx-disable-with="Marking..."
              >
                <.icon name="pi-check-bold" class="size-4" />Mark tested
              </.button>
            </div>
          </div>

          <div :if={!@advancing} class="flex-1 overflow-y-auto px-6 py-5">
            <div class="max-w-5xl mx-auto space-y-6">
              <.notice :if={@notice} notice={@notice} issue={@issue} />

              <section :if={@issue} id="testing-notes" class="space-y-2">
                <form
                  id={"testing-notes-form-#{@issue.id}"}
                  phx-change="save_notes"
                  class="group space-y-2"
                >
                  <input type="hidden" name="issue_id" value={@issue.id} />
                  <div class="flex items-center gap-3">
                    <label
                      for={"testing-notes-#{@issue.id}"}
                      class="text-sm font-semibold text-slate-900 dark:text-slate-100"
                    >
                      Testing notes
                    </label>
                    <span
                      :if={@in_queue}
                      id="testing-notes-status"
                      class="inline-flex items-center gap-1 text-xs text-slate-500 dark:text-slate-400"
                    >
                      <span class="hidden group-[.phx-change-loading]:inline-flex items-center gap-1">
                        <.icon name="pi-circle-notch" class="size-3 motion-safe:animate-spin" />Saving...
                      </span>
                      <span class="group-[.phx-change-loading]:hidden">Saves as you type</span>
                    </span>
                    <span
                      :if={!@in_queue}
                      id="testing-notes-status"
                      class="inline-flex items-center gap-1 text-xs text-slate-500 dark:text-slate-400"
                    >
                      <.icon name="pi-lock-simple" class="size-3" />{@lock_label}
                    </span>
                  </div>
                  <textarea
                    id={"testing-notes-#{@issue.id}"}
                    name="notes"
                    phx-debounce="500"
                    phx-blur="notes_blurred"
                    data-rev={@notes_rev}
                    readonly={!@in_queue}
                    placeholder="What you tried, what worked, what did not..."
                    class={[
                      "block w-full min-h-32 resize-y rounded-xl border-0 px-4 py-3 text-[13.5px] leading-relaxed text-slate-800 dark:text-slate-200 placeholder-slate-400 dark:placeholder-slate-500 focus:outline-none break-words",
                      @in_queue &&
                        "bg-white dark:bg-slate-900 ring-1 ring-slate-300 dark:ring-slate-600 focus:ring-2 focus:ring-blue-500",
                      !@in_queue &&
                        "bg-slate-50 dark:bg-slate-800/40 ring-1 ring-slate-200 dark:ring-slate-700"
                    ]}
                  >{@issue.testing_notes}</textarea>
                </form>
                <p :if={@in_queue} class="text-xs text-slate-500 dark:text-slate-400">
                  Send to triage opens a new ticket in Triage with these notes and a link to {@issue.identifier}.
                </p>
              </section>

              <div :if={@issue} class="border-t border-slate-200 dark:border-slate-800"></div>

              <.issue_view
                :if={@issue}
                issue={@issue}
                current_scope={@current_scope}
                blockers={@blockers}
                cycles={@cycles}
                show_task={false}
                read_only
              />
            </div>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  def handle_event("save_notes", %{"issue_id" => issue_id, "notes" => notes}, socket) do
    %{issue: open, queue: queue, current_scope: scope} = socket.assigns
    open? = match?(%Issue{id: ^issue_id}, open)
    # A save the debounce flushed as another row opened still belongs to the ticket it was typed on.
    issue = if open?, do: open, else: Enum.find(queue, &(&1.id == issue_id))
    result = issue && Issues.save_testing_notes(scope, issue, notes)

    socket =
      case {result, open?} do
        {{:ok, saved}, true} ->
          testing = %{open | testing_notes: saved.testing_notes, testing_state: saved.testing_state}
          socket |> assign(:issue, testing) |> assign_issue_flags()

        {{:error, reason}, _open} ->
          notice = %{for: socket.assigns.selected_id, reason: reason, identifier: issue.identifier}
          socket |> assign(:notice, notice) |> load()

        {_saved_elsewhere_or_unknown, _open} ->
          socket
      end

    {:noreply, socket}
  end

  # A second click arrives after the first moved the page on, so it names the ticket it was meant for.
  # While the loading screen shows, a click sent from the old buttons falls to the clause below.
  def handle_event(
        event,
        %{"issue_id" => issue_id},
        %{assigns: %{issue: %Issue{id: issue_id} = issue, advancing: nil}} = socket
      )
      when event in ["mark_tested", "send_to_triage"] do
    %{current_scope: scope, queue: queue} = socket.assigns

    result =
      if event == "mark_tested",
        do: Issues.mark_issue_tested(scope, issue),
        else: Issues.send_issue_to_triage(scope, issue)

    socket =
      case result do
        {:ok, finished} ->
          # The ticket after it in the queue, or the first other one when it was last or already gone.
          next =
            queue |> Enum.drop_while(&(&1.id != issue.id)) |> Enum.at(1) || Enum.find(queue, &(&1.id != issue.id))

          sent = if event == "send_to_triage", do: %{for: next && next.id, sent: finished, identifier: issue.identifier}
          label = if next, do: "Opening #{next.identifier}...", else: "Updating the queue..."
          # A double click's second click lands on this screen, not on the next ticket's buttons.
          advancing = %{from: issue.id, to: next, label: label}
          Process.send_after(self(), {:advance, advancing}, @advance_ms)

          socket |> assign(:notice, sent) |> assign(:advancing, advancing)

        {:error, reason} ->
          socket
          |> assign(:notice, %{for: socket.assigns.selected_id, reason: reason, identifier: issue.identifier})
          |> load()
      end

    {:noreply, socket}
  end

  # Leaving the field shows the notes saved last, which another tester's save may have replaced.
  def handle_event("notes_blurred", _params, socket), do: {:noreply, update(socket, :notes_rev, &(&1 + 1))}

  def handle_event(event, _params, socket) when event in ["mark_tested", "send_to_triage"], do: {:noreply, socket}

  # A ticket reaching Done joins the queue, and one leaving it drops out, from whatever wrote it. The open ticket is
  # read again when it or a relative changed, and Linear asked for blockers only when it or a blocker did.
  def handle_info({event, changed_id}, socket) when event in [:issue_changed, :issue_created] do
    %{issue: issue, blockers: blockers} = socket.assigns
    blocker_ids = for %{issue: %Issue{id: id}} <- (blockers && blockers.blocked_by ++ blockers.blocks) || [], do: id

    socket =
      cond do
        is_nil(issue) -> load(socket)
        issue_relative?(issue, blockers, changed_id) -> load(socket)
        true -> load_queue(socket)
      end

    socket =
      if issue != nil and (changed_id == issue.id or changed_id in blocker_ids), do: read_blockers(socket), else: socket

    {:noreply, socket}
  end

  def handle_info({:issues_synced, project_id}, socket) do
    socket =
      if match?(%Issue{project_id: ^project_id}, socket.assigns.issue) or is_nil(socket.assigns.issue),
        do: load(socket),
        else: load_queue(socket)

    {:noreply, socket}
  end

  def handle_info({event, issue_id}, %{assigns: %{issue: %Issue{id: issue_id}}} = socket)
      when event in [:issue_comments_changed, :testing_notes_changed] do
    {:noreply, load(socket)}
  end

  # Only the move its own action set off: a row opened since cleared it.
  def handle_info({:advance, advancing}, %{assigns: %{advancing: advancing}} = socket) do
    {:noreply, push_patch(socket, to: if(advancing.to, do: ~p"/testing/#{advancing.to.id}", else: ~p"/testing"))}
  end

  def handle_info({:cycles_changed, project_id}, %{assigns: %{issue: %Issue{project_id: project_id}}} = socket) do
    socket = socket |> load() |> read_cycles()
    {:noreply, socket}
  end

  # The navigation hook, the issue dialog, other tickets' notes and comments, other projects' cycles and a move a row
  # click cancelled say things this page has no use for.
  def handle_info(_message, socket), do: {:noreply, socket}

  # An answer read for a ticket the page no longer shows is dropped.
  def handle_async(:blockers, {:ok, {issue_id, blockers}}, %{assigns: %{issue: %Issue{id: issue_id}}} = socket) do
    {:noreply, assign(socket, :blockers, blockers)}
  end

  def handle_async(:blockers, _stale_or_failed, socket), do: {:noreply, socket}

  attr :notice, :map, required: true
  attr :issue, :any, required: true

  defp notice(%{notice: %{sent: created}} = assigns) do
    assigns = assign(assigns, :created, created)

    ~H"""
    <div id="testing-notice" class={notice_class()}>
      <.icon name="pi-tray-fill" class="size-4 text-slate-400 mt-0.5" />
      <span>
        {@notice.identifier} sent to triage as <.link
          navigate={~p"/issues/#{@created.identifier}"}
          id="testing-notice-created"
          class="font-mono font-semibold underline underline-offset-2"
        >{@created.identifier}</.link>.
      </span>
    </div>
    """
  end

  defp notice(%{notice: %{reason: :testing_finished}} = assigns) do
    assigns = assign(assigns, :finished, finished_label(assigns.issue))

    ~H"""
    <div id="testing-notice" class={notice_class()}>
      <.icon name="pi-info-fill" class="size-4 text-slate-400 mt-0.5" />
      <span>
        <span class="font-semibold">{@notice.identifier} {@finished}.</span> Nothing was changed.
      </span>
    </div>
    """
  end

  defp notice(%{notice: %{reason: :no_notes}} = assigns) do
    ~H"""
    <div id="testing-notice" class={notice_class()}>
      <.icon name="pi-info-fill" class="size-4 text-slate-400 mt-0.5" />
      <span>Write testing notes to send this to triage.</span>
    </div>
    """
  end

  defp notice(assigns) do
    ~H"""
    <div
      id="testing-notice"
      class="rounded-xl border border-red-300 dark:border-red-800 bg-red-50 dark:bg-red-950/30 px-4 py-3 flex items-start gap-2.5 text-[13px] text-red-800 dark:text-red-200 break-words"
    >
      <.icon name="pi-warning-circle" class="size-4 mt-0.5" />
      <span>That did not work: {inspect(@notice.reason)}</span>
    </div>
    """
  end

  defp notice_class,
    do:
      "rounded-xl border border-slate-300 dark:border-slate-600 bg-slate-50 dark:bg-slate-800/60 px-4 py-3 flex items-start gap-2.5 text-[13px] text-slate-800 dark:text-slate-200 break-words"

  defp finished_label(%Issue{state: :done, testing_state: :tested}), do: "was already marked tested"
  defp finished_label(%Issue{state: :done, testing_state: :sent_to_triage}), do: "was already sent to triage"
  defp finished_label(_moved_or_gone), do: "is no longer in Done"

  defp lock_label(%Issue{state: :done, testing_state: state}) when state in [:tested, :sent_to_triage],
    do: "Testing finished"

  defp lock_label(%Issue{state: :done}), do: "Not in the testing queue"
  defp lock_label(_not_done), do: "Not in Done"

  # The ticket the URL names, else the one already open, else the first in the queue. It stays open once it leaves the
  # queue; only a patch, which selects again, moves on from it.
  defp load(socket, mode \\ :keep) do
    socket = load_queue(socket)
    %{queue: queue, selected_id: selected_id, current_scope: scope, issue: shown} = socket.assigns
    open_id = if mode == :keep and shown, do: shown.id
    id = selected_id || open_id || (List.first(queue) && List.first(queue).id)

    # A ticket in a project the user cannot open is one that does not exist, as far as they can tell.
    issue =
      with id when is_binary(id) <- id,
           {:ok, issue} <- Issues.get_issue(id, preload: @preload),
           true <- Scope.can_access_project?(scope, issue.project_id) do
        issue
      else
        _not_found -> nil
      end

    socket = socket |> assign(:issue, issue) |> assign_issue_flags()

    if issue && shown && issue.id == shown.id,
      do: socket,
      else: socket |> assign(:blockers, nil) |> read_blockers() |> read_cycles()
  end

  defp load_queue(socket) do
    %{issues: queue} = Issues.list_issues(project_id: socket.assigns.project_filter, testing: true, preload: [:project])

    socket
    |> assign(:now, DateTime.utc_now())
    |> assign(:queue, queue)
  end

  defp assign_issue_flags(%{assigns: %{issue: issue}} = socket) do
    socket
    |> assign(:in_queue, issue != nil and Issue.in_testing_queue?(issue))
    |> assign(:show_testing_state, issue != nil and issue.state == :done and issue.testing_state != nil)
    |> assign(:notes_blank, issue == nil or String.trim(issue.testing_notes || "") == "")
    |> assign(:lock_label, issue && lock_label(issue))
  end

  # Read once connected and only when the open ticket or a blocker changes, so saving notes never asks Linear.
  defp read_blockers(%{assigns: %{issue: %Issue{} = issue}} = socket) do
    if connected?(socket) do
      start_async(socket, :blockers, fn ->
        {issue.id, Map.get(Issues.get_blockers([issue]), issue.external_id, %{blocked_by: [], blocks: []})}
      end)
    else
      socket
    end
  end

  defp read_blockers(socket), do: socket

  # Only Rail schedules a ticket's cycles; any other ticket shows no cycle row.
  defp read_cycles(%{assigns: %{issue: %Issue{tracker: :local, project: project}}} = socket) do
    {:ok, %{cycles: cycles}} = Issues.get_cycles(project)
    assign(socket, :cycles, cycles)
  end

  defp read_cycles(socket), do: assign(socket, :cycles, nil)
end
