defmodule RailWeb.Live.TaskActions do
  @moduledoc """
  Every decision a person makes on a task, in the page's header, shown for where the task is and who is reading:

  - the initial plan: its owner sends it to the tech leads or starts without approval, and a tech lead approves
    it, also after its owner started it, while a "Plan not approved" chip says it has not been. At Plan, Approve
    waits on the lead's own unsent plan comments, which approving would delete;
  - a branch the default branch has moved past: Update, which merges it in as a round of its own;
  - a round QA skipped as changing nothing a person sees: Run QA anyway;
  - a review with nothing left to fix: Ready for review, then a tech lead's Approve and Merge, none of them while
    the review agent works or its fix plan waits.

  A later round's plan is approved where it is read, beside it, so it is not here.
  """
  use RailWeb, :live_component

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.FixPlan
  alias Rail.Pipeline.Schemas.Round
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Roles.Schemas.Role
  alias Rail.Scope
  alias Rail.Users

  @impl true
  def update(assigns, socket) do
    {reload_approvals, assigns} = Map.pop(assigns, :reload_approvals, false)

    socket =
      socket
      |> forget_other_task(assigns)
      |> assign(assigns)
      |> assign_new(:error, fn -> nil end)
      |> assign_new(:merging, fn -> false end)
      |> assign_new(:approving, fn -> false end)
      |> assign_new(:approvals, fn -> [] end)
      |> assign_new(:own_approval, fn -> nil end)
      |> assign_new(:approvals_task_id, fn -> nil end)
      |> load()
      |> read_approvals(reload_approvals)

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="task-actions"
      data-qa="task_actions"
      class="flex items-center flex-wrap justify-end gap-2"
    >
      <span
        :if={@error}
        id="task-actions-error"
        role="alert"
        class="text-xs text-red-600 dark:text-red-500"
      >
        {@error}
      </span>

      <.button
        :if={@failed}
        id="task-retry"
        phx-click="retry"
        phx-value-run={@failed.id}
        phx-target={@myself}
        phx-disable-with="Starting…"
        title={@failed.error}
      >
        <.icon name="pi-arrow-clockwise" class="size-4" />Retry {@failed.role.name}
      </.button>

      <.button
        :if={@skipped}
        id="task-run-qa"
        phx-click="retry"
        phx-value-run={@skipped.id}
        phx-target={@myself}
        phx-disable-with="Starting…"
        title="This round changed only files nobody sees in the app, so QA did not run on it."
      >
        <.icon name="pi-play" class="size-4" />Run QA anyway
      </.button>

      <span
        :if={@plan.unapproved}
        id="task-plan-unapproved"
        data-qa="task_plan_unapproved"
        class="inline-flex items-center gap-1.5 rounded-full px-2.5 py-0.5 text-xs font-semibold bg-amber-100 dark:bg-amber-950 text-amber-800 dark:text-amber-300"
      >
        <.icon name="pi-seal-warning" class="size-3.5" /> Plan not approved
      </span>

      <span
        :if={@plan.sent}
        id="task-plan-sent"
        data-qa="task_plan_sent"
        class="inline-flex items-center gap-1.5 text-xs font-semibold text-slate-500 dark:text-slate-400"
      >
        <.icon name="pi-paper-plane-tilt" class="size-3.5" /> Sent to the tech leads
      </span>

      <.button
        :if={@plan.send}
        id="task-send-plan"
        phx-click="send_plan"
        phx-target={@myself}
        phx-disable-with="Sending…"
      >
        <.icon name="pi-paper-plane-tilt" class="size-4" />Send plan to lead
      </.button>

      <.button
        :if={@plan.start}
        id="task-start-plan"
        phx-click="start_plan"
        phx-target={@myself}
        phx-disable-with="Starting…"
      >
        <.icon name="pi-play" class="size-4" />Start without approval
      </.button>

      <.button
        :if={@plan.approve}
        id="task-approve-plan"
        variant="primary"
        phx-click="approve_plan"
        phx-target={@myself}
        phx-disable-with="Approving…"
        disabled={@unsent_comments > 0}
        title={@unsent_comments > 0 && unsent(@unsent_comments)}
      >
        <.icon name="pi-check" class="size-4" />Approve plan
      </.button>

      <span
        :if={@update and @task.base_conflicts != []}
        id="task-conflicts"
        data-qa="task_conflicts"
        role="status"
        title={"Merging #{@task.project.default_branch} in conflicts in:\n" <> Enum.join(@task.base_conflicts, "\n")}
        class="inline-flex items-center gap-1.5 rounded-full px-2.5 py-0.5 text-xs font-semibold bg-red-100 dark:bg-red-950 text-red-800 dark:text-red-300 ring-1 ring-inset ring-red-200 dark:ring-red-900"
      >
        <.icon name="pi-warning-fill" class="size-3.5" />
        {conflicts(@task.base_conflicts)} with {@task.project.default_branch}
      </span>

      <.button
        :if={@update}
        id="task-update"
        phx-click="update_branch"
        phx-target={@myself}
        phx-disable-with="Updating…"
        title={"Merge #{@task.project.default_branch} in, as a round of its own"}
      >
        <.icon name="pi-arrows-clockwise" class="size-4" />Update
      </.button>

      <.button
        :if={@state == :not_ready}
        id="task-ready-for-review"
        variant="primary"
        phx-click="mark_ready"
        phx-target={@myself}
        phx-disable-with="Marking…"
      >
        <.icon name="pi-flag" class="size-4" />Ready for review
      </.button>

      <span
        :if={@state in [:ready, :merging, :refused] and not @tech_lead}
        id="task-waiting"
        class="inline-flex items-center gap-1.5 text-xs text-slate-500 dark:text-slate-400"
      >
        <.icon name="pi-hourglass-medium" class="size-3.5" />{waiting(@tech_leads)}
      </span>

      <span
        :if={@state == :refused}
        id="task-merge-error"
        role="alert"
        title={@task.merge_error}
        class="inline-flex items-center gap-1.5 text-xs font-semibold text-red-600 dark:text-red-400"
      >
        <.icon name="pi-warning-circle" class="size-3.5" />GitHub refused the merge
      </span>

      <span
        :if={@approvals != [] and @state != :not_ready}
        id="task-approvals"
        class="inline-flex items-center gap-1.5 text-xs text-slate-600 dark:text-slate-300"
      >
        <.icon name="pi-seal-check" class="size-3.5" />Approved by {Enum.map_join(
          @approvals,
          ", ",
          &approver/1
        )}
      </span>

      <span
        :if={@own_approval}
        id="task-approved"
        class="inline-flex items-center gap-1.5 text-xs font-semibold text-emerald-600 dark:text-emerald-400"
      >
        <.icon name="pi-check-circle-fill" class="size-3.5" />Approved by you
      </span>

      <.button
        :if={@state in [:ready, :merging, :refused] and @tech_lead and !@own_approval}
        id="task-approve"
        phx-click="approve"
        phx-target={@myself}
        disabled={@approving}
      >
        <.icon
          name={if @approving, do: "pi-circle-notch", else: "pi-check-bold"}
          class={["size-4", @approving && "motion-safe:animate-spin"]}
        />
        {if @approving, do: "Approving…", else: "Approve"}
      </.button>

      <.button
        :if={@state in [:ready, :merging, :refused] and @tech_lead}
        id="task-merge"
        variant="primary"
        phx-click="merge"
        phx-target={@myself}
        disabled={@state == :merging or @merging}
        title={"Squash into #{@task.project.default_branch}"}
      >
        <.icon
          name={if @state == :merging or @merging, do: "pi-circle-notch", else: "pi-git-merge"}
          class={["size-4", (@state == :merging or @merging) && "motion-safe:animate-spin"]}
        />
        {if @state == :merging or @merging, do: "Merging…", else: "Merge"}
      </.button>

      <span
        :if={@state == :merged}
        id="task-merged"
        class="inline-flex items-center gap-1.5 text-xs font-semibold text-emerald-600 dark:text-emerald-400"
      >
        <.icon name="pi-git-merge-fill" class="size-3.5" />Merged by {name(@task.merged_by)}
      </span>
    </div>
    """
  end

  @impl true
  def handle_event("send_plan", _params, socket) do
    socket.assigns.current_scope |> Pipeline.send_plan_to_lead(socket.assigns.plan_run) |> respond(socket)
  end

  def handle_event("start_plan", _params, socket) do
    socket.assigns.current_scope |> Pipeline.start_plan(socket.assigns.plan_run) |> respond(socket)
  end

  def handle_event("approve_plan", _params, socket) do
    socket.assigns.current_scope |> Pipeline.approve_plan(socket.assigns.plan_run) |> respond(socket)
  end

  def handle_event("update_branch", _params, socket) do
    socket.assigns.current_scope |> Pipeline.update_branch(socket.assigns.task) |> respond(socket)
  end

  def handle_event("retry", %{"run" => run_id}, socket) do
    socket.assigns.current_scope |> Pipeline.retry_run(%Run{id: run_id}) |> respond(socket)
  end

  def handle_event("mark_ready", _params, socket) do
    socket.assigns.current_scope |> Pipeline.mark_ready(socket.assigns.task) |> respond(socket)
  end

  def handle_event("merge", _params, %{assigns: %{merging: true}} = socket), do: {:noreply, socket}

  def handle_event("merge", _params, socket) do
    %{current_scope: scope, task: task} = socket.assigns

    socket =
      socket
      |> assign(:merging, true)
      |> assign(:error, nil)
      |> start_async(:merge, fn ->
        # Unlinked, so leaving the page does not cut a merge off between GitHub's answer and recording it.
        Rail.TaskSupervisor
        |> Elixir.Task.Supervisor.async_nolink(fn -> Pipeline.merge_task(scope, task) end)
        |> Elixir.Task.await(:infinity)
      end)

    {:noreply, socket}
  end

  def handle_event("approve", _params, %{assigns: %{approving: true}} = socket), do: {:noreply, socket}

  def handle_event("approve", _params, socket) do
    %{current_scope: scope, task: task} = socket.assigns

    socket =
      socket
      |> assign(:approving, true)
      |> assign(:error, nil)
      |> start_async(:approve, fn ->
        # Unlinked, so leaving the page does not cut an approval off between GitHub's answer and telling every tab.
        approval = Elixir.Task.Supervisor.async_nolink(Rail.TaskSupervisor, fn -> Pipeline.approve_task(scope, task) end)
        {task.id, Elixir.Task.yield(approval, :infinity)}
      end)

    {:noreply, socket}
  end

  # GitHub's refusal is the task's own, so the header shows it from the row like every other tab does.
  @impl true
  def handle_async(:merge, {:ok, result}, socket) do
    send(self(), :task_changed)

    error =
      case result do
        {:ok, _merged} -> nil
        {:error, {:merge_refused, _message}} -> nil
        {:error, reason} -> merge_message(reason)
      end

    socket = socket |> assign(:merging, false) |> assign(:error, error)
    {:noreply, socket}
  end

  def handle_async(:merge, {:exit, _reason}, socket) do
    send(self(), :task_changed)
    socket = socket |> assign(:merging, false) |> assign(:error, "The merge did not finish. Try again.")
    {:noreply, socket}
  end

  # Split children share this header: another child's answer is dropped, and its approvals come back on the broadcast.
  def handle_async(:approve, {:ok, {task_id, _outcome}}, %{assigns: %{task: %Task{id: shown_id}}} = socket)
      when task_id != shown_id, do: {:noreply, socket}

  # GitHub took it but could not be read back; the broadcast has every page, this one too, read it again.
  def handle_async(:approve, {:ok, {_task_id, {:ok, {:ok, :unread}}}}, socket),
    do: {:noreply, assign(socket, :approving, false)}

  def handle_async(:approve, {:ok, {_task_id, {:ok, {:ok, approvals}}}}, socket) do
    socket = socket |> assign(:approving, false) |> assign_approvals(approvals)
    {:noreply, socket}
  end

  def handle_async(:approve, {:ok, {_task_id, {:ok, {:error, reason}}}}, socket) do
    socket = socket |> assign(:approving, false) |> assign(:error, approve_message(reason))
    {:noreply, socket}
  end

  def handle_async(:approve, {:ok, {_task_id, {:exit, _reason}}}, socket) do
    socket = socket |> assign(:approving, false) |> assign(:error, "The approval did not finish. Try again.")
    {:noreply, socket}
  end

  # coveralls-ignore-start (the approval never started, as when the task supervisor is shutting down in a deploy)
  def handle_async(:approve, {:exit, _reason}, socket) do
    socket = socket |> assign(:approving, false) |> assign(:error, "The approval did not finish. Try again.")
    {:noreply, socket}
  end

  # coveralls-ignore-stop

  # A read for a task the header has since left, or one GitHub failed, leaves the approvals as they were.
  def handle_async(:approvals, {:ok, {task_id, {:ok, approvals}}}, %{assigns: %{task: %Task{id: task_id}}} = socket),
    do: {:noreply, assign_approvals(socket, approvals)}

  def handle_async(:approvals, _unread, socket), do: {:noreply, socket}

  defp forget_other_task(%{assigns: %{task: %Task{id: shown_id}}} = socket, %{task: %Task{id: next_id}})
       when next_id != shown_id do
    socket
    |> assign(:approving, false)
    |> assign(:error, nil)
    |> assign(:approvals_task_id, nil)
    |> assign(:approvals, [])
    |> assign(:own_approval, nil)
  end

  defp forget_other_task(socket, _assigns), do: socket

  defp load(socket) do
    %{task: task, current_scope: scope} = socket.assigns
    tech_lead = Scope.tech_lead?(scope)
    state = if task.stage == :merged or (task.stage == :finalize and not revising?(task)), do: Task.finalize_state(task)

    socket
    |> assign(:tech_lead, tech_lead)
    |> assign(:state, state)
    |> assign(:plan_run, plan_run(task))
    |> assign(:failed, failed_run(task))
    |> assign(:skipped, skipped_run(task))
    |> assign(:plan, plan_actions(task, socket.assigns[:rounds] || Pipeline.list_rounds(task), scope, tech_lead))
    |> assign_unsent_comments()
    |> assign(:update, task.stage in [:review, :finalize] and task.base_behind and is_nil(task.cleaned_up_at))
    |> assign(
      :tech_leads,
      if(tech_lead or state in [nil, :not_ready, :merged], do: [], else: Users.list_tech_leads(task.project_id))
    )
  end

  # Changes are coming while the review agent works or its fix plan waits, so nothing is ready to review or merge.
  defp revising?(%Task{runs: runs} = task) do
    Enum.any?(runs, &(match?(%Run{role: %Role{stage: :review_lead}}, &1) and Run.running?(&1))) or
      match?(%FixPlan{approved_at: nil}, Pipeline.read_fix_plan(task))
  end

  defp plan_run(%Task{runs: runs}) when is_list(runs), do: Enum.find(runs, &match?(%Run{role: %Role{stage: :plan}}, &1))

  defp plan_run(%Task{}), do: nil

  # A failed run of the step the task is at, which nothing else starts again.
  defp failed_run(%Task{runs: runs, stage: stage}) when is_list(runs) and stage in [:engineer, :review] do
    retryable = if stage == :engineer, do: [:engineer], else: [:qa, :review, :demo, :review_lead]
    Enum.find(runs, &(&1.role.stage in retryable and Run.state(&1) == :failed))
  end

  defp failed_run(%Task{}), do: nil

  # QA skipped on a round that changed nothing a person sees, which a person may still want walked.
  defp skipped_run(%Task{runs: runs, stage: :review} = task) when is_list(runs) do
    if not Task.running?(task), do: Enum.find(runs, &(&1.role.stage == :qa and &1.stage_outcome == :skipped))
  end

  defp skipped_run(%Task{}), do: nil

  # What the initial plan asks of this reader. Its owner sends it or starts it; a tech lead approves it once sent,
  # straight away when they own it, and later when the owner started it without approval.
  defp plan_actions(%Task{} = task, rounds, %Scope{} = scope, lead?) do
    none = %{send: false, start: false, approve: false, sent: false, unapproved: false}

    case List.first(rounds) do
      %Round{approved_at: nil, plan: plan, ready_at: ready_at} when task.stage == :plan and is_binary(plan) ->
        initial_plan(
          none,
          Task.owned_by?(task, scope),
          lead?,
          ready_at != nil or scope.system,
          Run.running?(plan_run(task))
        )

      %Round{approved_at: nil} when task.stage != :plan and task.parent_task_id == nil ->
        %{none | unapproved: true, approve: lead? and task.stage != :merged}

      _approved_or_none ->
        none
    end
  end

  # Only at Plan does approving delete the reader's unsent comments, so only there does Approve wait on them.
  defp assign_unsent_comments(%{assigns: %{plan: %{approve: true}, task: %Task{stage: :plan}}} = socket) do
    %{current_scope: scope, task: task} = socket.assigns
    assign(socket, :unsent_comments, length(Pipeline.list_plan_comments(scope, task)))
  end

  defp assign_unsent_comments(socket), do: assign(socket, :unsent_comments, 0)

  # Nothing is offered while Plan works, since what would be sent or approved is still changing.
  defp initial_plan(none, _owner?, _lead?, _sent?, true), do: none

  defp initial_plan(none, owner?, lead?, sent?, false) do
    %{
      none
      | send: owner? and not lead? and not sent?,
        start: owner? and not lead?,
        approve: lead? and (owner? or sent?),
        sent: sent? and not lead?
    }
  end

  # Read once a task is past Ready for review and again when an approval lands, never on every refresh of the task.
  defp read_approvals(%{assigns: %{state: state}} = socket, _reload) when state in [nil, :not_ready], do: socket

  defp read_approvals(socket, reload) do
    %{task: task, approvals_task_id: read_for} = socket.assigns

    cond do
      read_for != task.id ->
        socket
        |> assign(:approvals_task_id, task.id)
        |> assign_approvals([])
        |> start_async(:approvals, fn -> {task.id, Pipeline.list_approvals(task)} end)

      reload ->
        start_async(socket, :approvals, fn -> {task.id, Pipeline.list_approvals(task)} end)

      true ->
        socket
    end
  end

  defp assign_approvals(socket, approvals) do
    login = socket.assigns.current_scope.user && socket.assigns.current_scope.user.login

    socket
    |> assign(:approvals, approvals)
    |> assign(:own_approval, Enum.find(approvals, &(&1.login == login)))
  end

  defp respond({:ok, _result}, socket) do
    send(self(), :task_changed)
    {:noreply, assign(socket, :error, nil)}
  end

  # A refusal usually means the task moved under the page, so the page reads it again.
  defp respond({:error, reason}, socket) do
    send(self(), :task_changed)
    {:noreply, assign(socket, :error, message(reason))}
  end

  defp unsent(1), do: "Send or remove your unsent comment first."
  defp unsent(count), do: "Send or remove your #{count} unsent comments first."

  defp conflicts([_one]), do: "Conflicts in 1 file"
  defp conflicts(paths), do: "Conflicts in #{length(paths)} files"

  defp waiting([]), do: "Waiting for a tech lead"

  defp waiting(leads) do
    names = Enum.map(leads, &name/1)
    "Waiting for a tech lead: " <> Enum.join(Enum.drop(names, -1), ", ") <> or_last(names)
  end

  defp or_last([only]), do: only
  defp or_last(names), do: " or " <> List.last(names)

  defp approver(%{user: %{} = user}), do: name(user)
  defp approver(%{login: login}), do: login

  # A user deleted since, or a GitHub merger with no Rail account, leaves the record with nobody's name on it.
  defp name(%{name: name, login: login}), do: if(name in [nil, ""], do: login, else: name)
  defp name(_nobody), do: "someone"

  defp message(:stage_running), do: "Something is still running on this task."
  defp message(:not_authorized), do: "Only a tech lead can approve a plan."
  defp message(:not_found), do: "This task is not in a project you can open."
  defp message(:plan_not_ready), do: "The plan's owner has not sent it to the tech leads yet."
  defp message(:already_approved), do: "The plan is already approved."
  defp message({:unanswered_questions, 1}), do: "Answer or dismiss the open question first."
  defp message({:unanswered_questions, count}), do: "Answer or dismiss the #{count} open questions first."
  defp message({:unsent_comments, count}), do: unsent(count)
  defp message(:not_owner), do: "Only the task's owner sends or starts its plan."
  defp message(:up_to_date), do: "The branch is already up to date."
  defp message(:not_retryable), do: "That run is not one to retry now."
  defp message(:no_pull_request), do: "This task has no pull request yet."
  defp message(:no_ticket), do: "Plan has not saved a ticket yet."
  defp message(:no_plan), do: "Plan has not saved a plan yet."
  defp message(:nothing_picked), do: "Pick a design before approving."
  defp message(:plan_not_for_pick), do: "The plan is not written for the picked design yet."
  defp message(:screenshot_missing), do: "The picked design has no screenshot yet."
  defp message(:stale_screenshot), do: "The screenshot is older than the design. Ask Plan to retake it."
  defp message({:invalid_stage, stage}), do: "This task is at #{Task.stage_label(stage)}."
  # coveralls-ignore-start (a refusal nobody has written a sentence for yet)
  defp message(reason), do: "That did not go through: #{inspect(reason)}"
  # coveralls-ignore-stop

  defp merge_message(:not_authorized), do: "Only a tech lead can merge a task."
  defp merge_message(:not_ready), do: "Mark the task ready for review before merging it."
  defp merge_message(:plan_not_approved), do: "A tech lead approves the plan before the task merges."
  defp merge_message(:merging), do: "A merge is already under way."
  defp merge_message(:merged), do: "This task is already merged."
  defp merge_message(:no_pull_request), do: "This task has no pull request to merge."
  defp merge_message(:no_github_token), do: "Sign in with GitHub again to merge. Nothing was sent."
  defp merge_message({:invalid_stage, stage}), do: "This task is at #{Task.stage_label(stage)}, not Finalize."

  defp approve_message({:approve_refused, said}), do: "GitHub refused the approval: #{said}"
  defp approve_message(:no_github_token), do: "Sign in with GitHub again to approve. Nothing was sent."
  defp approve_message(:not_authorized), do: "Only a tech lead can approve a task."
  defp approve_message(:not_ready), do: "Mark the task ready for review before approving it."
  defp approve_message(:merged), do: "This task is already merged."
  defp approve_message(:no_pull_request), do: "This task has no pull request to approve."
  defp approve_message({:invalid_stage, stage}), do: "This task is at #{Task.stage_label(stage)}, not Finalize."
  # GitHub could not be read, or never answered the approval, so the lead tries again and finds it if it landed.
  defp approve_message(_unfinished), do: "The approval did not finish. Try again."
end
