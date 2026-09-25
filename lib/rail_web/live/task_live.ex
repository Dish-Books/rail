defmodule RailWeb.TaskLive do
  @moduledoc """
  One task, read a tab at a time: the issue it came from, then a tab per role
  with that role's work on the left and its conversation on the right.

  A tab is the whole page - the work and the conversation move together - and it
  is in the URL, so a refresh comes back to it. The role a human picks stays
  picked until the task moves to another stage, when the role for the new stage
  takes the page over. A role that has not run has nothing to read, so it has no
  tab until it does.

  The page owns one thing the components cannot: the `run:<id>` subscription. A
  LiveComponent may not subscribe, so log lines arrive here and are forwarded to
  the conversation with `send_update/2`.
  """
  use RailWeb, :live_view

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Roles.Schemas.Role
  alias Rail.Users
  alias RailWeb.Live.ArchitectStage
  alias RailWeb.Live.DemoStage
  alias RailWeb.Live.DesignStage
  alias RailWeb.Live.EngineerStage
  alias RailWeb.Live.ProductStage
  alias RailWeb.Live.QaStage
  alias RailWeb.Live.ReviewStage
  alias RailWeb.Live.RunConversation

  # The engineer writes files as it works and the pane reads them off disk, so a
  # reader watching a run wants the diff to keep up. Re-reading on every batch of
  # log lines would shell out to git several times a second, so it is throttled to
  # this; the turn finishing re-reads regardless of when the last one was.
  @diff_refresh_ms 5_000

  @issue_tab "issue"

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
      |> assign(:conversation_run, nil)
      |> assign(:pane, :issue)
      |> assign(:diff_refreshed_at, nil)
      |> assign(:approvable, false)
      |> assign(:tabs, [])
      |> assign(:issue, nil)
      |> assign(:assignees, Users.list_linear_users())
      |> assign(:assignee_query, "")
      |> assign(:comment_nonce, 0)
      |> assign(:subscribed_run_ids, MapSet.new())
      |> assign(:watched_browser_task_id, nil)
      |> assign(:roles_map, %{})
      |> assign(:pending_question, nil)
      |> assign(:pending_questions, [])
      |> assign(:selected_question_id, nil)
      |> assign(:answer_text, "")
      |> assign(:answers_to_send?, false)
      |> assign(:cleaning_up, false)
      |> assign(:focus_file, nil)
      |> assign(:engineer_tab, nil)

    {:ok, socket}
  end

  def handle_params(%{"id" => task_id} = params, _uri, socket) do
    socket =
      socket
      |> assign(:task_id, task_id)
      |> assign(:url_tab, params["tab"])
      |> assign(:selected_tab, params["tab"])
      |> assign(:focus_file, params["file"])
      |> refresh_task()

    {:noreply, socket}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} {assigns}>
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
          :if={@task != nil and @pane == :product}
          module={ProductStage}
          id={stage_component_id(@selected_role)}
          task={@task}
          run={@selected_run}
          approvable={@approvable}
        >
          <:tabs><.task_tabs tabs={@tabs} /></:tabs>
          <:actions>
            <.claim_button task={@task} />
            <.rebase_button task={@task} engineer_tab={@engineer_tab} />
            <.cleanup_button task={@task} cleaning_up={@cleaning_up} />
          </:actions>
          <:sidebar>
            <.conversation_sidebar
              task={@task}
              roles_map={@roles_map}
              answers_to_send?={@answers_to_send?}
              pending_question={@pending_question}
              pending_questions={@pending_questions}
              answer_text={@answer_text}
              conversation_run={@conversation_run}
            />
          </:sidebar>
        </.live_component>

        <.live_component
          :if={@task != nil and @pane == :design}
          module={DesignStage}
          id={stage_component_id(@selected_role)}
          task={@task}
          run={@selected_run}
          approvable={@approvable}
        >
          <:tabs><.task_tabs tabs={@tabs} /></:tabs>
          <:actions>
            <.claim_button task={@task} />
            <.rebase_button task={@task} engineer_tab={@engineer_tab} />
            <.cleanup_button task={@task} cleaning_up={@cleaning_up} />
          </:actions>
          <:sidebar>
            <.conversation_sidebar
              task={@task}
              roles_map={@roles_map}
              answers_to_send?={@answers_to_send?}
              pending_question={@pending_question}
              pending_questions={@pending_questions}
              answer_text={@answer_text}
              conversation_run={@conversation_run}
            />
          </:sidebar>
        </.live_component>

        <.live_component
          :if={@task != nil and @pane == :architect}
          module={ArchitectStage}
          id={stage_component_id(@selected_role)}
          task={@task}
          run={@selected_run}
          approvable={@approvable}
        >
          <:tabs><.task_tabs tabs={@tabs} /></:tabs>
          <:actions>
            <.claim_button task={@task} />
            <.rebase_button task={@task} engineer_tab={@engineer_tab} />
            <.cleanup_button task={@task} cleaning_up={@cleaning_up} />
          </:actions>
          <:sidebar>
            <.conversation_sidebar
              task={@task}
              roles_map={@roles_map}
              answers_to_send?={@answers_to_send?}
              pending_question={@pending_question}
              pending_questions={@pending_questions}
              answer_text={@answer_text}
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
          approvable={@approvable}
          current_scope={@current_scope}
          focus_file={@focus_file}
        >
          <:tabs><.task_tabs tabs={@tabs} /></:tabs>
          <:actions>
            <.claim_button task={@task} />
            <.rebase_button task={@task} engineer_tab={@engineer_tab} />
            <.cleanup_button task={@task} cleaning_up={@cleaning_up} />
          </:actions>
          <:sidebar>
            <.conversation_sidebar
              task={@task}
              roles_map={@roles_map}
              answers_to_send?={@answers_to_send?}
              pending_question={@pending_question}
              pending_questions={@pending_questions}
              answer_text={@answer_text}
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
          approvable={@approvable}
          current_scope={@current_scope}
          engineer_tab={@engineer_tab}
        >
          <:tabs><.task_tabs tabs={@tabs} /></:tabs>
          <:actions>
            <.claim_button task={@task} />
            <.rebase_button task={@task} engineer_tab={@engineer_tab} />
            <.cleanup_button task={@task} cleaning_up={@cleaning_up} />
          </:actions>
          <:sidebar>
            <.conversation_sidebar
              task={@task}
              roles_map={@roles_map}
              answers_to_send?={@answers_to_send?}
              pending_question={@pending_question}
              pending_questions={@pending_questions}
              answer_text={@answer_text}
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
          approvable={@approvable}
          current_scope={@current_scope}
        >
          <:tabs><.task_tabs tabs={@tabs} /></:tabs>
          <:actions>
            <.claim_button task={@task} />
            <.rebase_button task={@task} engineer_tab={@engineer_tab} />
            <.cleanup_button task={@task} cleaning_up={@cleaning_up} />
          </:actions>
          <:sidebar>
            <.conversation_sidebar
              task={@task}
              roles_map={@roles_map}
              answers_to_send?={@answers_to_send?}
              pending_question={@pending_question}
              pending_questions={@pending_questions}
              answer_text={@answer_text}
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
          approvable={@approvable}
          current_scope={@current_scope}
        >
          <:tabs><.task_tabs tabs={@tabs} /></:tabs>
          <:actions>
            <.claim_button task={@task} />
            <.rebase_button task={@task} engineer_tab={@engineer_tab} />
            <.cleanup_button task={@task} cleaning_up={@cleaning_up} />
          </:actions>
          <:sidebar>
            <.conversation_sidebar
              task={@task}
              roles_map={@roles_map}
              answers_to_send?={@answers_to_send?}
              pending_question={@pending_question}
              pending_questions={@pending_questions}
              answer_text={@answer_text}
              conversation_run={@conversation_run}
            />
          </:sidebar>
        </.live_component>

        <!-- The issue is the same view the issue page shows, and it is read on its
        own: there is no one role whose conversation belongs beside it. -->
        <.task_layout
          :if={@task != nil and @pane == :issue and @issue != nil}
          task={@task}
          title={@task.issue.title}
        >
          <:tabs><.task_tabs tabs={@tabs} /></:tabs>
          <:actions>
            <.claim_button task={@task} />
            <.rebase_button task={@task} engineer_tab={@engineer_tab} />
            <.cleanup_button task={@task} cleaning_up={@cleaning_up} />
          </:actions>
          <.issue_view
            issue={@issue}
            assignees={@assignees}
            assignee_query={@assignee_query}
            comment_nonce={@comment_nonce}
            show_task={false}
          />
        </.task_layout>

        <.task_layout
          :if={@task != nil and @pane == :none}
          task={@task}
          run={@selected_run}
          title={@task.issue.title}
        >
          <:tabs><.task_tabs tabs={@tabs} /></:tabs>
          <:actions>
            <.claim_button task={@task} />
            <.rebase_button task={@task} engineer_tab={@engineer_tab} />
            <.cleanup_button task={@task} cleaning_up={@cleaning_up} />
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
              roles_map={@roles_map}
              answers_to_send?={@answers_to_send?}
              pending_question={@pending_question}
              pending_questions={@pending_questions}
              answer_text={@answer_text}
              conversation_run={@conversation_run}
            />
          </:sidebar>
        </.task_layout>
      </div>
    </Layouts.app>
    """
  end

  def handle_event("select_tab", %{"tab" => tab}, socket) do
    socket =
      socket
      |> assign(:selected_question_id, nil)
      |> push_patch(to: ~p"/tasks/#{socket.assigns.task_id}?tab=#{tab}")

    {:noreply, socket}
  end

  def handle_event("select_option", %{"option" => option}, socket) do
    {:noreply, assign(socket, :answer_text, option)}
  end

  def handle_event("select_question", %{"question_id" => question_id}, socket) do
    socket =
      socket
      |> assign(:selected_question_id, question_id)
      |> assign(:answer_text, "")
      |> refresh_task()

    {:noreply, socket}
  end

  def handle_event("answer_form_change", params, socket) do
    {:noreply, assign(socket, :answer_text, Map.get(params, "answer") || "")}
  end

  def handle_event("answer_question", params, socket) do
    answer = params |> Map.get("answer", socket.assigns.answer_text) |> to_string() |> String.trim()

    if answer == "" do
      {:noreply, socket}
    else
      _answered = socket |> question_id(params) |> answer_one(answer)
      {:noreply, reset_answer(socket)}
    end
  end

  def handle_event("dismiss_question", params, socket) do
    _dismissed = socket |> question_id(params) |> dismiss_one()
    {:noreply, reset_answer(socket)}
  end

  def handle_event("send_answers", _params, socket) do
    _sent = Pipeline.send_answers(socket.assigns.conversation_run)
    {:noreply, refresh_task(socket)}
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
        {:ok, _issue} -> socket
        {:error, reason} -> put_flash(socket, :error, claim_error(reason))
      end

    {:noreply, refresh_task(socket)}
  end

  def handle_event("rebase", _params, socket) do
    socket =
      case Pipeline.rebase_task(socket.assigns.current_scope, socket.assigns.task) do
        {:ok, _task} -> socket
        {:error, reason} -> put_flash(socket, :error, rebase_error(reason))
      end

    # The rebase is the engineer's work, and its tab is where it shows.
    {:noreply, push_patch(socket, to: ~p"/tasks/#{socket.assigns.task_id}?tab=#{socket.assigns.engineer_tab}")}
  end

  def handle_info({:run_events, run_id, events}, socket) do
    if MapSet.member?(socket.assigns.subscribed_run_ids, run_id) do
      send_update(RunConversation, id: "run-conversation", run_id: run_id, appended_events: events)
    end

    socket = socket |> refresh_diff() |> refresh_written(events)

    {:noreply, socket}
  end

  # A frame goes to the client rather than through the component. It is a picture
  # arriving several times a second and nothing on the page depends on it, so
  # re-rendering the panel around it would be paying for a diff of everything
  # else to move one image.
  def handle_info({:browser_frame, task_id, data}, socket) do
    if socket.assigns.task_id == task_id and socket.assigns.pane in [:qa, :demo] do
      {:noreply, push_event(socket, "browser:frame", %{data: data})}
    else
      {:noreply, socket}
    end
  end

  # A queued message went out, or came back, on its own time.
  def handle_info({:run_changed, _run_id}, socket) do
    {:noreply, refresh_task(socket)}
  end

  # A finished turn may have rewritten the ticket, the design or the plan on disk
  # without changing a row, so the stage is told to read it again rather than left
  # to notice.
  def handle_info({:os_process_finished, _run, _outcome}, socket) do
    socket = refresh_task(socket)

    case socket.assigns do
      %{pane: :product, task: task, selected_role: role} ->
        send_update(ProductStage, id: stage_component_id(role), task: task)

      %{pane: :design, task: task, selected_role: role} ->
        send_update(DesignStage, id: stage_component_id(role), task: task)

      %{pane: :architect, task: task, selected_role: role} ->
        send_update(ArchitectStage, id: stage_component_id(role), task: task)

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

    {:noreply, socket}
  end

  # A stage sends this once the human picks or approves something on it.
  def handle_info(:task_changed, socket) do
    {:noreply, refresh_task(socket)}
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

  # Only a branch the engineer has built has anything to rebase, and only a task
  # nothing is working on can be rebased under it.
  defp rebase_button(assigns) do
    ~H"""
    <button
      :if={@task.cleaned_up_at == nil and @engineer_tab != nil}
      type="button"
      id="rebase-task"
      data-qa="rebase_task"
      phx-click="rebase"
      disabled={Task.running?(@task)}
      title={"Rebase onto origin/#{@task.project.default_branch}"}
      class="px-4 py-2 rounded-lg border border-slate-300 dark:border-slate-600 text-sm font-semibold text-slate-900 dark:text-slate-100 hover:bg-slate-50 dark:hover:bg-slate-800 cursor-pointer disabled:opacity-50 disabled:cursor-not-allowed"
    >
      {if @task.is_rebasing and Task.running?(@task), do: "Rebasing…", else: "Rebase"}
    </button>
    """
  end

  attr :task, :any, required: true

  # Nobody owns an issue until somebody claims it.
  defp claim_button(assigns) do
    ~H"""
    <button
      :if={@task.cleaned_up_at == nil and @task.issue.owner_user_id == nil}
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

  # A cleaned-up task is history: there is nothing left on disk to clean.
  defp cleanup_button(assigns) do
    ~H"""
    <button
      :if={@task.cleaned_up_at == nil}
      type="button"
      id="cleanup-task"
      data-qa="cleanup_task"
      phx-click="cleanup"
      data-confirm="Clean up this task? Its worktree and scratch files will be deleted."
      disabled={@cleaning_up}
      class="px-4 py-2 rounded-lg border border-red-300 dark:border-red-800 text-sm font-semibold text-red-600 dark:text-red-400 hover:bg-red-50 dark:hover:bg-red-950 cursor-pointer disabled:opacity-50"
    >
      {if @cleaning_up, do: "Cleaning up…", else: "Clean up"}
    </button>
    """
  end

  attr :task, :any, required: true
  attr :roles_map, :map, required: true
  attr :answers_to_send?, :boolean, required: true
  attr :pending_question, :any, required: true
  attr :pending_questions, :list, required: true
  attr :answer_text, :string, required: true
  attr :conversation_run, :any, required: true

  # Questions sit above the conversation they came out of.
  defp conversation_sidebar(assigns) do
    ~H"""
    <div :if={@pending_question != nil} class="p-4 border-b border-slate-200 dark:border-slate-700">
      <.answer_field
        question={@pending_question}
        questions={@pending_questions}
        answer_text={@answer_text}
      />
    </div>

    <!-- Answering only records. The round reaches the agent when the human says it is done. -->
    <div
      :if={@answers_to_send? and @pending_question == nil}
      id="send-answers-panel"
      data-qa="send_answers_panel"
      class="flex items-center justify-between gap-2 p-4 border-b border-slate-200 dark:border-slate-700"
    >
      <span class="text-xs text-slate-500 dark:text-slate-400">
        Every question is answered.
      </span>

      <button
        type="button"
        id="send-answers-button"
        data-qa="send-answers-button"
        phx-click="send_answers"
        class="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-xs font-semibold bg-blue-600 dark:bg-blue-500 text-white hover:opacity-90 cursor-pointer shadow-xs"
      >
        Send answers
      </button>
    </div>

    <.live_component
      module={RunConversation}
      id="run-conversation"
      task={@task}
      runs={@task.runs || []}
      stage_run={@conversation_run}
      roles_map={@roles_map}
    />
    """
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

  # What a running stage writes goes to disk, so nothing tells the panel it moved.
  # The run says so in its own log as it happens, and that is already being
  # carried here: QA's checklist fills a row at a time, and a demo's captions land
  # as they are narrated.
  defp refresh_written(%{assigns: %{pane: :qa, task: task, selected_role: role}} = socket, events) do
    if Enum.any?(events, &checklist_line?/1) do
      send_update(QaStage, id: stage_component_id(role), task: task)
    end

    socket
  end

  defp refresh_written(%{assigns: %{pane: :demo, task: task, selected_role: role}} = socket, events) do
    if Enum.any?(events, &beat_line?/1) do
      send_update(DemoStage, id: stage_component_id(role), task: task)
    end

    socket
  end

  defp refresh_written(socket, _events), do: socket

  defp checklist_line?(%{line: line}), do: String.starts_with?(line, ["[qa] plan ", "[qa] check "])

  defp beat_line?(%{line: line}), do: String.starts_with?(line, "[demo] say ")

  defp due?(nil, _now), do: true
  defp due?(last, now), do: now - last >= @diff_refresh_ms

  defp refresh_task(socket) do
    case Pipeline.get_task(socket.assigns.task_id) do
      {:ok, task} -> socket |> apply_task(task) |> sync_tab_url()
      {:error, _reason} -> assign(socket, :task, nil)
    end
  end

  defp apply_task(socket, %Task{} = task) do
    roles = if task.project_id, do: Rail.Roles.list_roles(task.project_id), else: []
    started = started_roles(roles, task)
    {role, selected_run} = select_tab(started, task, socket.assigns.selected_tab, socket.assigns.tab_stage)

    asked = Pipeline.list_questions(task, order_by: [asc: :inserted_at, asc: :id])
    questions = Enum.filter(asked, &(&1.status == :pending))
    pending_questions = questions_for(questions, selected_run)
    pending_question = select_question(pending_questions, socket.assigns.selected_question_id)

    socket
    |> assign(:task, task)
    |> assign(:page_title, task.issue.title)
    |> assign(:roles_map, Map.new(roles, &{&1.id, &1}))
    |> assign(:selected_tab, (role && role.id) || @issue_tab)
    |> assign(:tab_stage, task.stage)
    |> assign(:selected_role, role)
    |> assign(:selected_run, selected_run)
    |> assign(:conversation_run, selected_run)
    |> assign(:pane, pane(role))
    # Nothing is approved while its run is still working on it.
    |> assign(
      :approvable,
      role != nil and role.stage == task.stage and selected_run != nil and not Run.running?(selected_run)
    )
    |> assign(:tabs, build_tabs(task, started, role, questions))
    |> assign(:engineer_tab, engineer_tab(started))
    |> assign(:answers_to_send?, answers_to_send?(asked, selected_run))
    |> assign(:subscribed_run_ids, sync_run_subscriptions(socket, task.runs))
    |> assign(:watched_browser_task_id, watch_browser(socket, task))
    |> assign(:pending_questions, pending_questions)
    |> assign(:pending_question, pending_question)
    |> assign(:selected_question_id, pending_question && pending_question.id)
    |> load_issue(task)
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
  defp started_roles(roles, %Task{runs: runs, stage: stage}) do
    roles
    |> Enum.map(&{&1, role_run(runs, &1)})
    |> Enum.reject(fn {role, run} -> run == nil and not (role.stage == :demo and stage == :demo) end)
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

  # Once the URL names a tab it keeps naming the one that is open, so a refresh
  # comes back here even after the task has moved the page on. A URL that names
  # none is left alone: it already means "wherever the task is now".
  defp sync_tab_url(%{assigns: %{url_tab: url_tab, selected_tab: selected}} = socket) when url_tab in [nil, selected] do
    socket
  end

  defp sync_tab_url(%{assigns: %{selected_tab: tab, task_id: task_id}} = socket) do
    push_patch(socket, to: ~p"/tasks/#{task_id}?tab=#{tab}")
  end

  # A finding names a file, and the diff that file changed in is the engineer's
  # tab, so review can only link there once the engineer has a tab to link to.
  defp engineer_tab(started) do
    Enum.find_value(started, fn {role, _run} -> role.stage == :engineer and role.id end)
  end

  defp pane(nil), do: :issue
  defp pane(%Role{stage: stage}) when stage in [:product, :design, :architect, :engineer, :review, :qa, :demo], do: stage
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
          label: role.name,
          sublabel: role_status_label(role, run, task),
          tone: tab_tone(run),
          badge: Map.get(counts, run && run.id, 0),
          selected?: selected != nil and selected.id == role.id
        }
      end)

    [issue_tab | role_tabs]
  end

  defp tab_tone(run), do: Run.state(run)

  # A run can ask several things at once, so it shows the whole queue as tabs, in
  # the order they were asked. A run resumed without an answer still shows them.
  defp questions_for(questions, %Run{id: run_id}), do: Enum.filter(questions, &(&1.run_id == run_id))
  defp questions_for(_questions, nil), do: []

  # A round settled here but not yet sent, whether or not the run is still parked on it.
  defp answers_to_send?(asked, %Run{id: run_id}) do
    Enum.any?(asked, &(&1.run_id == run_id and &1.status in [:answered, :dismissed] and &1.delivered_at == nil))
  end

  defp answers_to_send?(_asked, nil), do: false

  # The tab the human picked stays put across refreshes; once it is answered the
  # front of the queue takes over.
  defp select_question(questions, selected_id) do
    Enum.find(questions, &(&1.id == selected_id)) || List.first(questions)
  end

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

  # One topic per task, carrying whatever its browser is painting. Subscribing
  # whatever the pane is, because the pane changes without the task changing and a
  # browser nobody is watching broadcasts to nobody at almost no cost.
  defp watch_browser(socket, %Task{id: task_id}) do
    watched = socket.assigns.watched_browser_task_id

    if connected?(socket) and watched != task_id do
      if watched, do: Phoenix.PubSub.unsubscribe(Rail.PubSub, "browser:#{watched}")
      Phoenix.PubSub.subscribe(Rail.PubSub, "browser:#{task_id}")
    end

    if connected?(socket), do: task_id, else: watched
  end

  defp question_id(socket, params) do
    Map.get(params, "question_id") || (socket.assigns.pending_question && socket.assigns.pending_question.id)
  end

  defp answer_one(question_id, answer) do
    with {:ok, question} <- Pipeline.get_question(question_id) do
      Pipeline.answer_question(question, answer)
    end
  end

  defp dismiss_one(question_id) do
    with {:ok, question} <- Pipeline.get_question(question_id) do
      Pipeline.dismiss_question(question)
    end
  end

  defp reset_answer(socket) do
    socket
    |> assign(:answer_text, "")
    |> assign(:selected_question_id, nil)
    |> refresh_task()
  end

  defp claim_error(:already_assigned), do: "Somebody else claimed this issue first"
  defp claim_error(:linear_not_linked), do: "Link your Linear account in Settings before claiming an issue"

  defp rebase_error(:task_busy), do: "Stop the task's run before rebasing it"
  defp rebase_error(:uncommitted_changes), do: "Commit the engineer's work before rebasing it"
  defp rebase_error(:no_worktree), do: "The task's worktree is gone, so there is nothing to rebase"
  defp rebase_error(reason) when is_binary(reason), do: "Could not rebase: #{reason}"
  defp rebase_error(reason), do: "Could not rebase: #{inspect(reason)}"
end
