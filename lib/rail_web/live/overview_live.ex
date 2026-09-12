defmodule RailWeb.OverviewLive do
  @moduledoc false
  use RailWeb, :live_view

  import RailWeb.CoreComponents,
    only: [
      approval_card: 1,
      compact_waiting_strip: 1,
      dispatch_banner: 1,
      empty_state: 1,
      question_card: 1,
      role_roster: 1,
      with_agent_section: 1
    ]

  alias Rail.Domain.AttentionQueue
  alias Rail.Domain.CompactStripBlock
  alias Rail.Domain.OverviewQueue
  alias Rail.Domain.OverviewQueueState
  alias Rail.Domain.QuestionAttentionItem
  alias Rail.Domain.SingleCardBlock
  alias Rail.Domain.TaskAttentionItem
  alias Rail.Pipeline
  alias Rail.Projects
  alias Rail.Roles

  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")
    end

    socket =
      socket
      |> assign(:page_title, "Overview")
      |> assign(:current_section, :overview)
      |> assign(:current_project_id, nil)
      |> assign(:running_count, 0)
      |> assign(:attention_queue, AttentionQueue.new())
      |> assign(:overview_queue, %OverviewQueueState{waiting: [], with_agent: []})
      |> assign(:roster_groups, [])
      |> assign(:dispatch_disabled, check_dispatch_disabled())
      |> assign(:submitting, false)
      |> assign(:show_send_back_modal, false)
      |> assign(:send_back_task, nil)
      |> assign(:show_merge_modal, false)
      |> assign(:merge_task, nil)
      |> assign(:show_rebase_modal, false)
      |> assign(:rebase_task, nil)

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
      |> assign(:page_title, "Overview")
      |> assign(:current_section, :overview)
      |> assign(:current_project_id, project_id)
      |> load_overview_state(project_id)

    {:noreply, socket}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_section={@current_section}
      is_rail_extended={@is_rail_extended}
      attention_count={@attention_count}
      current_project_id={@current_project_id}
      projects={@projects}
      theme={@theme}
      show_project_switcher={@show_project_switcher}
      show_new_issue_modal={@show_new_issue_modal}
      capture_ask={@capture_ask}
      capture_project_id={@capture_project_id}
      capture_priority={@capture_priority}
      capture_error={@capture_error}
      capture_submitting={@capture_submitting}
    >
      <div id="overview-view" data-qa="overview-view" class="space-y-6">
        <!-- Header row: Overview in bold + running agents pill -->
        <div class="flex items-center space-x-3" id="overview-header" data-qa="overview-hero">
          <h1
            class="text-2xl font-bold tracking-tight text-slate-900 dark:text-slate-100"
            id="overview-title"
            data-qa="overview_title"
          >
            Overview
          </h1>
          <span
            id="running-agent-count-pill"
            data-qa="running_agent_count_pill"
            class="px-2.5 py-1 rounded-full text-xs font-semibold bg-slate-200 dark:bg-slate-600 text-slate-900 dark:text-slate-100"
          >
            {running_agents_label(@running_count)}
          </span>
        </div>

        <!-- Optional Dispatch-Disabled Banner -->
        <.dispatch_banner :if={@dispatch_disabled} visible={@dispatch_disabled} />

        <!-- Main Layout: 2 Columns (Main Queue on Left, Role Roster on Right) -->
        <div class="flex items-start gap-6">
          <!-- Main Queue Column -->
          <div class="flex-1 min-w-0" id="overview-main-queue">
            <!-- "WAITING ON YOU · {count}" Section -->
            <div :if={@overview_queue.waiting != []} id="waiting-on-you-section" class="mb-6">
              <h2
                id="waiting-header"
                data-qa="waiting-header"
                class="text-xs font-bold uppercase tracking-wider text-slate-500 dark:text-slate-400 mb-3"
              >
                WAITING ON YOU · {length(@overview_queue.waiting)}
              </h2>

              <div class="space-y-3" id="waiting-blocks-list">
                <div :for={block <- @overview_queue.waiting}>
                  <.question_card
                    :if={match?(%SingleCardBlock{row: %{kind: :question}}, block)}
                    row={block.row}
                    submitting={@submitting}
                  />

                  <.approval_card
                    :if={match?(%SingleCardBlock{row: %{kind: :approval}}, block)}
                    row={block.row}
                  />

                  <.compact_waiting_strip
                    :if={match?(%CompactStripBlock{}, block)}
                    block={block}
                  />
                </div>
              </div>
            </div>

            <!-- "WITH AN AGENT · {count} · RECENTLY UPDATED" Section -->
            <.with_agent_section rows={@overview_queue.with_agent} />

            <!-- "All clear" Empty State (only when waiting and with_agent are both empty) -->
            <.empty_state :if={@overview_queue.waiting == [] and @overview_queue.with_agent == []} />
          </div>

          <!-- Role Roster Sidebar -->
          <.role_roster groups={@roster_groups} is_filtered={@current_project_id != nil} />
        </div>

        <!-- Send Back Comments Modal -->
        <div
          :if={@show_send_back_modal and @send_back_task}
          id="send-back-modal"
          data-qa="send-back-modal"
          class="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4"
        >
          <div class="w-full max-w-lg rounded-2xl bg-white dark:bg-slate-900 border border-slate-200 dark:border-slate-700 p-6 shadow-2xl space-y-4">
            <div class="flex items-center justify-between border-b border-slate-200 dark:border-slate-700 pb-3">
              <h2
                class="text-base font-semibold text-slate-900 dark:text-slate-100"
                id="send-back-modal-title"
              >
                Send back with comments
              </h2>
              <button
                type="button"
                id="close-send-back-button"
                data-qa="close-send-back-button"
                phx-click="close_send_back"
                class="text-slate-500 dark:text-slate-400 hover:text-slate-900 dark:hover:text-slate-100 text-sm font-bold p-1 cursor-pointer"
              >
                ✕
              </button>
            </div>

            <p class="text-xs text-slate-500 dark:text-slate-400">
              Describe what should change for <span class="font-semibold text-slate-900 dark:text-slate-100">{@send_back_task.issue && @send_back_task.issue.title}</span>.
            </p>

            <form
              id="send-back-form"
              phx-submit="confirm_send_back"
              phx-change="send_back_change"
              class="space-y-4"
            >
              <input type="hidden" name="task_id" value={@send_back_task.id} />
              <textarea
                name="comment"
                id="send-back-comment-input"
                data-qa="send-back-comment-input"
                rows="4"
                required
                placeholder="What should change?"
                class="w-full px-3 py-2 text-xs rounded-lg border border-slate-500 dark:border-slate-400 bg-white dark:bg-slate-900 text-slate-900 dark:text-slate-100 placeholder-slate-500 dark:placeholder-slate-400 focus:outline-none focus:ring-1 focus:ring-blue-600 dark:focus:ring-blue-500"
              ></textarea>

              <div class="flex justify-end space-x-3 pt-2">
                <button
                  type="button"
                  phx-click="close_send_back"
                  class="px-3 py-1.5 rounded-lg border border-slate-500 dark:border-slate-400 text-xs font-semibold text-slate-900 dark:text-slate-100 hover:bg-slate-50 dark:hover:bg-slate-800 cursor-pointer"
                >
                  Cancel
                </button>
                <button
                  type="submit"
                  id="submit-send-back-button"
                  data-qa="submit-send-back-button"
                  class="px-3 py-1.5 rounded-lg bg-blue-600 dark:bg-blue-500 text-white text-xs font-semibold hover:opacity-90 cursor-pointer shadow-xs"
                >
                  Send back
                </button>
              </div>
            </form>
          </div>
        </div>

        <!-- Merge Confirmation Modal -->
        <div
          :if={@show_merge_modal and @merge_task}
          id="merge-confirm-modal"
          data-qa="merge-confirm-modal"
          class="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4"
        >
          <div class="w-full max-w-md rounded-2xl bg-white dark:bg-slate-900 border border-slate-200 dark:border-slate-700 p-6 shadow-2xl space-y-4">
            <h2
              class="text-base font-semibold text-slate-900 dark:text-slate-100"
              id="merge-modal-title"
            >
              Merge this pull request?
            </h2>
            <p class="text-xs text-slate-500 dark:text-slate-400">
              Squash-merges PR #{@merge_task.pr_number || "?"} for {@merge_task.issue &&
                @merge_task.issue.title} and deletes its branch.
            </p>

            <div class="flex justify-end space-x-3 pt-3">
              <button
                type="button"
                id="cancel-merge-button"
                data-qa="cancel-merge-button"
                phx-click="close_merge"
                class="px-3 py-1.5 rounded-lg border border-slate-500 dark:border-slate-400 text-xs font-semibold text-slate-900 dark:text-slate-100 hover:bg-slate-50 dark:hover:bg-slate-800 cursor-pointer"
              >
                Cancel
              </button>
              <button
                type="button"
                id="confirm-merge-button"
                data-qa="confirm-merge-button"
                phx-click="confirm_merge"
                phx-value-task_id={@merge_task.id}
                class="px-3 py-1.5 rounded-lg bg-emerald-700 hover:bg-emerald-600 text-white text-xs font-semibold cursor-pointer shadow-xs"
              >
                Merge
              </button>
            </div>
          </div>
        </div>

        <!-- Rebase Confirmation Modal -->
        <div
          :if={@show_rebase_modal and @rebase_task}
          id="rebase-confirm-modal"
          data-qa="rebase-confirm-modal"
          class="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4"
        >
          <div class="w-full max-w-md rounded-2xl bg-white dark:bg-slate-900 border border-slate-200 dark:border-slate-700 p-6 shadow-2xl space-y-4">
            <h2
              class="text-base font-semibold text-slate-900 dark:text-slate-100"
              id="rebase-modal-title"
            >
              Rebase this branch?
            </h2>
            <p class="text-xs text-slate-500 dark:text-slate-400">
              Rebases the branch for {@rebase_task.issue && @rebase_task.issue.title} onto the default branch, resolves conflicts, and force-pushes.
            </p>

            <div class="flex justify-end space-x-3 pt-3">
              <button
                type="button"
                id="cancel-rebase-button"
                data-qa="cancel-rebase-button"
                phx-click="close_rebase"
                class="px-3 py-1.5 rounded-lg border border-slate-500 dark:border-slate-400 text-xs font-semibold text-slate-900 dark:text-slate-100 hover:bg-slate-50 dark:hover:bg-slate-800 cursor-pointer"
              >
                Cancel
              </button>
              <button
                type="button"
                id="confirm-rebase-button"
                data-qa="confirm-rebase-button"
                phx-click="confirm_rebase"
                phx-value-task_id={@rebase_task.id}
                class="px-3 py-1.5 rounded-lg bg-amber-700 hover:bg-amber-600 text-white text-xs font-semibold cursor-pointer shadow-xs"
              >
                Rebase
              </button>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  def handle_event("answer_question", %{"question_id" => question_id, "answer" => answer}, socket) do
    answer_one(question_id, answer)

    socket = load_overview_state(socket, socket.assigns[:current_project_id])
    {:noreply, socket}
  end

  def handle_event("dismiss_question", %{"question_id" => question_id}, socket) do
    dismiss_question(question_id)

    socket = load_overview_state(socket, socket.assigns[:current_project_id])
    {:noreply, socket}
  end

  def handle_event("submit_question_answer", %{"question_id" => question_id, "answer" => answer}, socket) do
    case String.trim(answer) do
      "" ->
        {:noreply, socket}

      trimmed ->
        answer_one(question_id, trimmed)
        socket = load_overview_state(socket, socket.assigns[:current_project_id])
        {:noreply, socket}
    end
  end

  def handle_event("open_send_back", %{"task_id" => task_id}, socket) do
    case Pipeline.get_task(task_id) do
      {:ok, task} ->
        socket =
          socket
          |> assign(:send_back_task, task)
          |> assign(:show_send_back_modal, true)

        {:noreply, socket}

      _error ->
        {:noreply, socket}
    end
  end

  def handle_event("close_send_back", _params, socket) do
    socket =
      socket
      |> assign(:show_send_back_modal, false)
      |> assign(:send_back_task, nil)

    {:noreply, socket}
  end

  def handle_event("confirm_send_back", _params, socket) do
    socket =
      socket
      |> assign(:show_send_back_modal, false)
      |> assign(:send_back_task, nil)
      |> load_overview_state(socket.assigns[:current_project_id])

    {:noreply, socket}
  end

  def handle_event("open_merge", %{"task_id" => task_id}, socket) do
    case Pipeline.get_task(task_id) do
      {:ok, task} ->
        socket =
          socket
          |> assign(:merge_task, task)
          |> assign(:show_merge_modal, true)

        {:noreply, socket}

      _error ->
        {:noreply, socket}
    end
  end

  def handle_event("close_merge", _params, socket) do
    socket =
      socket
      |> assign(:show_merge_modal, false)
      |> assign(:merge_task, nil)

    {:noreply, socket}
  end

  def handle_event("confirm_merge", %{"task_id" => task_id}, socket) do
    Pipeline.merge_task(task_id)

    socket =
      socket
      |> assign(:show_merge_modal, false)
      |> assign(:merge_task, nil)
      |> load_overview_state(socket.assigns[:current_project_id])

    {:noreply, socket}
  end

  def handle_event("open_rebase", %{"task_id" => task_id}, socket) do
    case Pipeline.get_task(task_id) do
      {:ok, task} ->
        socket =
          socket
          |> assign(:rebase_task, task)
          |> assign(:show_rebase_modal, true)

        {:noreply, socket}

      _error ->
        {:noreply, socket}
    end
  end

  def handle_event("close_rebase", _params, socket) do
    socket =
      socket
      |> assign(:show_rebase_modal, false)
      |> assign(:rebase_task, nil)

    {:noreply, socket}
  end

  def handle_event("confirm_rebase", %{"task_id" => task_id}, socket) do
    Pipeline.start_rebase(task_id)

    socket =
      socket
      |> assign(:show_rebase_modal, false)
      |> assign(:rebase_task, nil)
      |> load_overview_state(socket.assigns[:current_project_id])

    {:noreply, socket}
  end

  # --- Private Helpers ---

  def handle_event("send_back_change", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("noop", _params, socket) do
    {:noreply, socket}
  end

  def handle_info({:pipeline_changed, _meta}, socket) do
    socket = load_overview_state(socket, socket.assigns[:current_project_id])
    {:noreply, socket}
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  defp load_overview_state(socket, project_id) do
    scope = socket.assigns[:current_scope]
    tasks = Pipeline.list_tasks(project_id, preload: [:project, :issue])
    questions = Pipeline.list_questions(project_id, status: :pending, preload: [:task, run: :role])

    questions_by_task_id = Map.new(questions, &{&1.task_id, &1})

    question_for = fn task -> questions_by_task_id[task.id] end

    waiting_tasks = Enum.filter(tasks, &OverviewQueue.needs_attention?/1)
    waiting_task_ids = MapSet.new(Enum.map(waiting_tasks, & &1.id))

    orphan_questions =
      Enum.filter(questions, fn q ->
        is_nil(q.task_id) or not MapSet.member?(waiting_task_ids, q.task_id)
      end)

    waiting_items =
      Enum.map(waiting_tasks, &TaskAttentionItem.new/1) ++
        Enum.map(orphan_questions, &QuestionAttentionItem.new/1)

    {ordered_waiting_items, updated_attention_queue} =
      AttentionQueue.reconcile(socket.assigns.attention_queue, waiting_items)

    overview_queue =
      OverviewQueue.build_overview_queue(
        ordered_waiting_items,
        tasks,
        question_for,
        fn key -> AttentionQueue.waiting_since(updated_attention_queue, key) end
      )

    running_count = Enum.count(tasks, fn t -> t.stage_state == :running end)
    roster_groups = build_roster_groups(scope, project_id, tasks)
    dispatch_disabled = check_dispatch_disabled()

    socket
    |> assign(:attention_queue, updated_attention_queue)
    |> assign(:overview_queue, overview_queue)
    |> assign(:running_count, running_count)
    |> assign(:roster_groups, roster_groups)
    |> assign(:dispatch_disabled, dispatch_disabled)
  end

  defp build_roster_groups(scope, project_id, tasks) when is_binary(project_id) do
    case Projects.get_project(scope, project_id) do
      {:ok, project} ->
        roles = Roles.list_roles(scope, project.id)
        entries = Enum.map(roles, &build_role_entry(&1, tasks))
        [{project, entries}]

      _other ->
        []
    end
  end

  defp build_roster_groups(scope, nil, tasks) do
    projects = Projects.list_projects(scope)

    Enum.map(projects, fn project ->
      project_tasks = Enum.filter(tasks, &(&1.project_id == project.id))
      roles = Roles.list_roles(scope, project.id)
      entries = Enum.map(roles, &build_role_entry(&1, project_tasks))
      {project, entries}
    end)
  end

  defp build_role_entry(role, tasks) do
    active_task =
      Enum.find(tasks, fn task ->
        task.active_chat_role_id == role.id or
          (Map.get(task, :current_role_id) == role.id and task.stage_state in [:running, :blocked]) or
          (role.stage != nil and task.stage == role.stage and
             task.stage_state in [:running, :blocked, :awaiting_approval, :paused_question, :paused_chat, :blocked_rework])
      end)

    waiting? =
      active_task != nil and
        active_task.stage_state in [:blocked, :awaiting_approval, :paused_question, :blocked_rework]

    subtitle =
      cond do
        is_nil(active_task) ->
          "Idle"

        waiting? ->
          "Waiting on you · #{task_key(active_task)}"

        active_task.active_chat_role_id != nil ->
          "#{task_key(active_task)} · chatting"

        true ->
          "#{task_key(active_task)} · running"
      end

    %{
      role: role,
      active_task: active_task,
      waiting?: waiting?,
      subtitle: subtitle
    }
  end

  defp task_key(%{issue: %{identifier: identifier}}) when is_binary(identifier) and identifier != "", do: identifier
  defp task_key(%{id: id}) when is_binary(id) and id != "", do: id

  defp check_dispatch_disabled do
    System.get_env("RAIL_NO_DISPATCH") == "1"
  end

  # Answers go back a round at a time: this records one and the task stays parked
  # until nothing is pending, so the agent hears the whole batch at once.
  defp answer_one(question_id, answer) do
    case Pipeline.get_question(question_id) do
      {:ok, question} -> Pipeline.answer_questions(question.task_id, %{question_id => answer})
      _not_found -> :ok
    end
  end

  defp running_agents_label(1), do: "1 agent running"
  defp running_agents_label(n), do: "#{n} agents running"

  defp dismiss_question(question_id) do
    case Pipeline.get_question(question_id) do
      {:ok, question} -> Pipeline.dismiss_question(question)
      _not_found -> :ok
    end
  end
end
