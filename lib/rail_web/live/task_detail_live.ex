defmodule RailWeb.TaskDetailLive do
  @moduledoc false
  use RailWeb, :live_view

  import RailWeb.CoreComponents,
    only: [
      icon: 1,
      project_badge: 1,
      stage_stepper: 1,
      stage_outcome: 1,
      markdown: 1,
      task_actions: 1,
      task_action_modals: 1,
      answer_field: 1,
      conversation_tab: 1,
      diff_pane: 1,
      demo_panel: 1,
      no_demo_banner: 1,
      demo_player_modal: 1,
      design_panel: 1
    ]

  alias Rail.Domain.ChatTranscript
  alias Rail.Domain.Formatters
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Pipeline.TaskActionRunner
  alias Rail.Runs
  alias Rail.Runs.Schemas.Run
  alias RailWeb.Components.DemoPlayerState

  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:task, nil)
      |> assign(:task_id, nil)
      |> assign(:page_title, "Task")
      |> assign(:current_section, :tasks)
      |> assign(:active_tab, :overview)
      |> assign(:current_run, nil)
      |> assign(:current_role_name, nil)
      |> assign(:runs, [])
      |> assign(:running_action, nil)
      |> assign(:active_modal, nil)
      |> assign(:design, nil)
      |> assign(:demo, nil)
      |> assign(:demo_player, nil)
      |> assign(:ticket_content, "")
      |> assign(:plan_content, nil)
      |> assign(:pending_question, nil)
      |> assign(:pending_questions, [])
      |> assign(:selected_question_id, nil)
      |> assign(:answer_text, "")
      |> assign(:ordered_runs, [])
      |> assign(:selected_role_id, nil)
      |> assign(:selected_run, nil)
      |> assign(:selected_role, nil)
      |> assign(:roles_map, %{})
      |> assign(:log_lines, [])
      |> assign(:transcript, nil)
      |> assign(:show_raw_log, false)
      |> assign(:expanded_activities, MapSet.new())
      |> assign(:chat_input, "")
      |> assign(:chat_sending, false)
      |> assign(:active_delivery_modal, nil)
      |> assign(:subscribed_run_id, nil)
      |> assign(:file_diffs, [])
      |> assign(:viewed_diff_files, %{})
      |> assign(:expanded_gaps, %{})
      |> assign(:selected_diff_file, nil)
      |> assign(:loading_diff, false)
      |> assign(:diff_rev, nil)

    {:ok, socket}
  end

  def handle_params(params, _uri, socket) do
    task_id = Map.get(params, "id")
    scope = socket.assigns[:current_scope]

    socket =
      if is_nil(socket.assigns[:task]) or socket.assigns[:task_id] != task_id do
        case Pipeline.get_task(scope, task_id) do
          {:ok, task} ->
            if connected?(socket) do
              Phoenix.PubSub.subscribe(Rail.PubSub, "tasks:#{task.id}")
              Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline_changed")
              Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")
            end

            apply_task_data(socket, task)

          {:error, _reason} ->
            socket
            |> assign(:task, nil)
            |> assign(:task_id, task_id)
            |> assign(:page_title, "Task")
            |> assign(:current_run, nil)
            |> assign(:current_role_name, nil)
            |> assign(:runs, [])
            |> assign(:running_action, nil)
            |> assign(:active_modal, nil)
            |> assign(:design, nil)
            |> assign(:demo, nil)
            |> assign(:demo_player, nil)
            |> assign(:ticket_content, "")
            |> assign(:plan_content, nil)
            |> assign(:pending_question, nil)
            |> assign(:pending_questions, [])
            |> assign(:selected_question_id, nil)
            |> assign(:answer_text, "")
            |> assign(:ordered_runs, [])
            |> assign(:selected_role_id, nil)
            |> assign(:selected_run, nil)
            |> assign(:selected_role, nil)
            |> assign(:roles_map, %{})
            |> assign(:log_lines, [])
            |> assign(:transcript, nil)
        end
      else
        socket
      end

    active_tab = parse_tab(Map.get(params, "tab"))

    socket =
      socket
      |> assign(:active_tab, active_tab)
      |> assign(:current_section, :tasks)
      |> maybe_load_diff(active_tab)

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
      <div id="task-detail-view" data-qa="task-detail-view" class="space-y-6">
        <%= if is_nil(@task) do %>
          <!-- Deleted / Cleaned Up State -->
          <div class="flex items-center justify-between" id="task-detail-header">
            <h1
              class="text-2xl font-bold tracking-tight text-slate-900 dark:text-slate-100"
              id="task-detail-title"
              data-qa="task_detail_title"
            >
              Task
            </h1>
          </div>

          <div
            id="task-cleaned-up"
            data-qa="task-cleaned-up"
            class="flex flex-col items-center justify-center min-h-[300px] text-center p-8 bg-white dark:bg-slate-900 rounded-xl border border-slate-200 dark:border-slate-700 shadow-xs"
          >
            <p class="text-base font-medium text-slate-500 dark:text-slate-400">
              This task has been cleaned up.
            </p>
          </div>
        <% else %>
          <!-- Task Header with Project Badge, Title & 4 Tabs in exact order -->
          <div
            id="task-header"
            data-qa="task-header"
            class="space-y-4 border-b border-slate-200 dark:border-slate-700 pb-0"
          >
            <div class="flex items-center gap-3">
              <.project_badge project={@task.project} />
              <h1
                class="text-2xl font-bold tracking-tight text-slate-900 dark:text-slate-100 truncate"
                id="task-detail-title"
                data-qa="task_detail_title"
                title={@task.issue && @task.issue.title}
              >
                {@task.issue && @task.issue.title}
              </h1>
            </div>

            <!-- Tabs (Overview, Plan, Conversation, Diff) -->
            <nav
              id="task-tabs"
              data-qa="task-tabs"
              class="flex items-center space-x-6 text-sm font-medium -mb-px"
            >
              <.link
                patch={~p"/tasks/#{@task.id}?tab=overview"}
                id="tab-overview"
                data-qa="tab-overview tab_overview"
                data-active={if @active_tab == :overview, do: "true", else: "false"}
                class={[
                  "pb-3 border-b-2 transition-colors cursor-pointer",
                  @active_tab == :overview &&
                    "border-blue-600 dark:border-blue-500 text-blue-600 dark:text-blue-500 font-bold",
                  @active_tab != :overview &&
                    "border-transparent text-slate-500 dark:text-slate-400 hover:text-slate-900 dark:hover:text-slate-100 hover:border-slate-300 dark:hover:border-slate-600"
                ]}
              >
                Overview
              </.link>

              <.link
                patch={~p"/tasks/#{@task.id}?tab=plan"}
                id="tab-plan"
                data-qa="tab-plan tab_plan"
                data-active={if @active_tab == :plan, do: "true", else: "false"}
                class={[
                  "pb-3 border-b-2 transition-colors cursor-pointer",
                  @active_tab == :plan &&
                    "border-blue-600 dark:border-blue-500 text-blue-600 dark:text-blue-500 font-bold",
                  @active_tab != :plan &&
                    "border-transparent text-slate-500 dark:text-slate-400 hover:text-slate-900 dark:hover:text-slate-100 hover:border-slate-300 dark:hover:border-slate-600"
                ]}
              >
                Plan
              </.link>

              <.link
                patch={~p"/tasks/#{@task.id}?tab=conversation"}
                id="tab-conversation"
                data-qa="tab-conversation tab_conversation"
                data-active={if @active_tab == :conversation, do: "true", else: "false"}
                class={[
                  "pb-3 border-b-2 transition-colors cursor-pointer",
                  @active_tab == :conversation &&
                    "border-blue-600 dark:border-blue-500 text-blue-600 dark:text-blue-500 font-bold",
                  @active_tab != :conversation &&
                    "border-transparent text-slate-500 dark:text-slate-400 hover:text-slate-900 dark:hover:text-slate-100 hover:border-slate-300 dark:hover:border-slate-600"
                ]}
              >
                Conversation
              </.link>

              <.link
                patch={~p"/tasks/#{@task.id}?tab=diff"}
                id="tab-diff"
                data-qa="tab-diff tab_diff"
                data-active={if @active_tab == :diff, do: "true", else: "false"}
                class={[
                  "pb-3 border-b-2 transition-colors cursor-pointer",
                  @active_tab == :diff &&
                    "border-blue-600 dark:border-blue-500 text-blue-600 dark:text-blue-500 font-bold",
                  @active_tab != :diff &&
                    "border-transparent text-slate-500 dark:text-slate-400 hover:text-slate-900 dark:hover:text-slate-100 hover:border-slate-300 dark:hover:border-slate-600"
                ]}
              >
                Diff
              </.link>
            </nav>
          </div>

          <!-- Tab 1: Overview Pane -->
          <div
            id="tab-overview-pane"
            data-qa="tab-overview-pane"
            class={[@active_tab != :overview && "hidden", "space-y-6"]}
          >
            <!-- Stage Stepper -->
            <.stage_stepper task={@task} runs={@runs} />

            <!-- Metadata Wrap -->
            <div
              id="task-metadata-wrap"
              data-qa="task-metadata-wrap"
              class="flex flex-wrap items-center gap-4 py-2 text-xs text-slate-500 dark:text-slate-400"
            >
              <!-- Stage Status Chip -->
              <span
                id="metadata-status-chip"
                data-qa="metadata-status-chip"
                class={[
                  "inline-flex items-center gap-1.5 px-3 py-1 rounded-full text-xs font-semibold shrink-0",
                  Formatters.stage_state_color_class(@task, :chip)
                ]}
              >
                <.icon name={Formatters.stage_state_icon(@task)} class="h-4 w-4 shrink-0" />
                <span>{Formatters.stage_label(@task)}</span>
              </span>

              <!-- Branch / Worktree Meta -->
              <div
                id="meta-branch"
                data-qa="meta-branch"
                class="flex items-center gap-1.5 shrink-0 font-mono"
              >
                <.icon name="pi-tree-structure" class="h-4 w-4 shrink-0" />
                <span>{branch_name_for(@task)}</span>
              </div>

              <!-- Issue Meta -->
              <div
                :if={issue_identifier_for(@task)}
                id="meta-issue"
                data-qa="meta-issue"
                class="flex items-center gap-1.5 shrink-0"
              >
                <.icon name="pi-lightbulb" class="h-4 w-4 shrink-0" />
                <span>{issue_identifier_for(@task)}</span>
              </div>

              <!-- PR Link -->
              <a
                :if={@task.pr_number}
                id="meta-pr"
                data-qa="meta-pr"
                href={pr_url_for(@task)}
                target="_blank"
                rel="noopener noreferrer"
                class="inline-flex items-center gap-1 text-blue-600 dark:text-blue-500 hover:underline shrink-0 font-semibold"
              >
                <.icon name="pi-git-merge" class="h-4 w-4 shrink-0" />
                <span>{"PR ##{@task.pr_number}"}</span>
                <.icon name="pi-arrow-square-out" class="h-3.5 w-3.5 shrink-0" />
              </a>

              <!-- Priority Meta -->
              <div
                id="meta-priority"
                data-qa="meta-priority"
                class="flex items-center gap-1.5 shrink-0"
              >
                <.icon name="pi-flag" class="h-4 w-4 shrink-0" />
                <span>{task_priority_label(@task)}</span>
              </div>
            </div>

            <!-- Conflict Banner -->
            <div
              :if={Formatters.has_merge_conflicts?(@task) and not @task.is_rebasing}
              id="conflict-banner"
              data-qa="conflict_banner"
              class="p-4 rounded-xl bg-amber-50 dark:bg-amber-950/50 border border-amber-300 dark:border-amber-800 text-amber-900 dark:text-amber-200"
            >
              <div class="flex items-start gap-3">
                <.icon name="pi-git-branch" class="h-5 w-5 shrink-0 mt-0.5" />
                <p class="text-xs leading-relaxed">
                  GitHub cannot merge {if @task.pr_number,
                    do: "PR ##{@task.pr_number}",
                    else: "this pull request"} into main: the base branch has moved and the change conflicts with it. Rebase to hand it back to the engineer - the task keeps its place in the pipeline.
                </p>
              </div>
            </div>

            <!-- Error Card -->
            <div
              :if={is_binary(@task.error) and @task.error != ""}
              id="task-error-card"
              data-qa="task_error_card"
              class="p-4 rounded-xl bg-red-100 dark:bg-red-900 border border-red-600 dark:border-red-500 text-red-800 dark:text-red-200"
            >
              <p class="text-xs font-mono whitespace-pre-wrap leading-relaxed">{@task.error}</p>
            </div>

            <!-- Task Actions Matrix -->
            <.task_actions
              task={@task}
              running_action={@running_action}
              design={@design}
              on_action="action_click"
            />

            <!-- Pending Question Card on Overview (spec 05 §2.6 / §5) -->
            <.answer_field
              :if={@task.stage_state == :blocked and @pending_question != nil}
              question={@pending_question}
              questions={@pending_questions}
              answer_text={@answer_text}
            />

            <!-- Design Panel (spec 05 §2.7 / §10) -->
            <.design_panel :if={@design != nil} design={@design} />

            <!-- Demo Panel / No-Demo Banner (spec 05 §2.8 / §9) -->
            <%= if @demo != nil do %>
              <.demo_panel demo={@demo} task={@task} />
            <% else %>
              <.no_demo_banner :if={@task.stage == :ready_to_merge} task={@task} />
            <% end %>

            <!-- Stage Outcome Component -->
            <.stage_outcome
              task={@task}
              run={@current_run}
              role_name={@current_role_name}
            />

            <!-- Ticket Section (Always Last on Overview) -->
            <div id="ticket-section" data-qa="ticket_section" class="space-y-2 pt-2">
              <h3 class="text-base font-bold text-slate-900 dark:text-slate-100">
                Ticket
              </h3>
              <div class="rounded-xl border border-slate-200 bg-slate-50 dark:border-slate-700 dark:bg-slate-800 p-4 select-text">
                <.markdown content={@ticket_content} />
              </div>
            </div>
          </div>

          <!-- Tab 2: Plan Pane -->
          <div
            id="tab-plan-pane"
            data-qa="tab-plan-pane"
            class={[@active_tab != :plan && "hidden"]}
          >
            <%= if is_nil(@plan_content) or @plan_content == "" do %>
              <div
                id="plan-empty-state"
                data-qa="plan_empty_state"
                class="flex items-center justify-center min-h-[300px] text-center p-8 bg-white dark:bg-slate-900 rounded-xl border border-slate-200 dark:border-slate-700 shadow-xs"
              >
                <p class="text-sm font-medium text-slate-500 dark:text-slate-400">
                  No plan has been written yet.
                </p>
              </div>
            <% else %>
              <div id="plan-content" data-qa="plan_content" class="space-y-4">
                <div class="rounded-xl border border-slate-200 bg-slate-50 dark:border-slate-700 dark:bg-slate-800 p-6 select-text">
                  <.markdown content={@plan_content} />
                </div>
              </div>
            <% end %>
          </div>

          <!-- Tab 3: Conversation Pane -->
          <div
            id="tab-conversation-pane"
            data-qa="tab-conversation-pane"
            class={[@active_tab != :conversation && "hidden"]}
          >
            <.conversation_tab
              task={@task}
              ordered_runs={@ordered_runs}
              selected_run={@selected_run}
              selected_role_id={@selected_role_id}
              selected_role={@selected_role}
              roles_map={@roles_map}
              log_lines={@log_lines}
              transcript={@transcript}
              show_raw_log={@show_raw_log}
              expanded_activities={@expanded_activities}
              chat_input={@chat_input}
              chat_sending={@chat_sending}
              active_delivery_modal={@active_delivery_modal}
            />
          </div>

          <!-- Tab 4: Diff Pane -->
          <div
            id="tab-diff-pane"
            data-qa="tab-diff-pane"
            class={[@active_tab != :diff && "hidden"]}
          >
            <%= if not Task.worktree_present?(@task) do %>
              <div
                id="diff-empty-state"
                data-qa="diff_empty_state"
                class="flex items-center justify-center min-h-[300px] text-center p-8 bg-white dark:bg-slate-900 rounded-xl border border-slate-200 dark:border-slate-700 shadow-xs"
              >
                <p class="text-sm font-medium text-slate-500 dark:text-slate-400">
                  This task has no worktree.
                </p>
              </div>
            <% else %>
              <%= if @loading_diff do %>
                <div
                  id="diff-loading-spinner"
                  data-qa="diff_loading_spinner"
                  class="flex items-center justify-center min-h-[300px]"
                >
                  <div
                    class="inline-block h-8 w-8 animate-spin rounded-full border-4 border-solid border-current border-e-transparent align-[-0.125em] text-blue-600 dark:text-blue-500 motion-reduce:animate-[spin_1.5s_linear_infinite]"
                    role="status"
                  >
                    <span class="sr-only">Loading diff...</span>
                  </div>
                </div>
              <% else %>
                <div class="space-y-3">
                  <div class="flex items-center justify-between gap-4 px-1 text-xs">
                    <div class="truncate text-slate-600 dark:text-slate-300 font-mono">
                      {@task.worktree_path}
                    </div>
                    <button
                      type="button"
                      id="btn-refresh-diff"
                      data-qa="btn_refresh_diff"
                      phx-click="refresh_diff"
                      class="inline-flex items-center gap-1.5 px-2.5 py-1 text-xs font-medium rounded-lg border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-900 text-slate-900 dark:text-slate-100 hover:bg-slate-100 dark:hover:bg-slate-700 transition-colors cursor-pointer"
                    >
                      <.icon name="pi-arrows-clockwise" class="w-3.5 h-3.5" />
                      <span>Refresh</span>
                    </button>
                  </div>

                  <.diff_pane
                    files={@file_diffs}
                    viewed={@viewed_diff_files}
                    expanded_gaps={@expanded_gaps}
                    selected_file={@selected_diff_file}
                  />
                </div>
              <% end %>
            <% end %>
          </div>

          <!-- Action Confirmation & Prompt Modals -->
          <.task_action_modals
            active_modal={@active_modal}
            task={@task}
            current_role_name={@current_role_name}
          />

          <!-- Demo Player Overlay Modal -->
          <.demo_player_modal :if={@demo_player != nil} player={@demo_player} />
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    if socket.assigns[:task] do
      {:noreply, push_patch(socket, to: ~p"/tasks/#{socket.assigns.task.id}?tab=#{tab}")}
    else
      {:noreply, socket}
    end
  end

  def handle_event("action_click", %{"action" => action} = params, socket) do
    handle_action_click(action, params, socket)
  end

  def handle_event("close_modal", _params, socket) do
    {:noreply, assign(socket, :active_modal, nil)}
  end

  def handle_event("modal_form_change", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("submit_modal", %{"action" => action} = params, socket) do
    handle_submit_modal(action, params, socket)
  end

  def handle_event("select_option", %{"option" => option}, socket) do
    {:noreply, assign(socket, :answer_text, option)}
  end

  def handle_event("select_question", params, socket) do
    socket =
      case Map.get(params, "question_id") do
        question_id when is_binary(question_id) ->
          socket
          |> assign(:selected_question_id, question_id)
          |> assign(:answer_text, "")
          |> refresh_task()

        _missing ->
          socket
      end

    {:noreply, socket}
  end

  def handle_event("answer_form_change", params, socket) do
    answer = Map.get(params, "answer") || ""
    {:noreply, assign(socket, :answer_text, answer)}
  end

  def handle_event("answer_question", params, socket) do
    answer = Map.get(params, "answer") || socket.assigns[:answer_text] || ""
    trimmed = String.trim(answer)

    if trimmed == "" do
      {:noreply, socket}
    else
      question_id =
        Map.get(params, "question_id") ||
          (socket.assigns[:pending_question] && socket.assigns.pending_question.id)

      scope = socket.assigns.current_scope

      if question_id do
        Pipeline.answer_question(scope, question_id, trimmed)
      end

      socket =
        socket
        |> assign(:answer_text, "")
        |> assign(:selected_question_id, nil)
        |> refresh_task()

      {:noreply, socket}
    end
  end

  def handle_event("dismiss_question", params, socket) do
    question_id =
      Map.get(params, "question_id") ||
        (socket.assigns[:pending_question] && socket.assigns.pending_question.id)

    scope = socket.assigns.current_scope

    if question_id do
      Pipeline.dismiss_question(scope, question_id)
    end

    socket =
      socket
      |> assign(:answer_text, "")
      |> assign(:selected_question_id, nil)
      |> refresh_task()

    {:noreply, socket}
  end

  def handle_event("select_role", %{"role_id" => role_id}, socket) do
    ordered_runs = socket.assigns[:ordered_runs] || []

    selected_run =
      Enum.find(ordered_runs, fn r ->
        r.role_id == role_id or to_string(r.role_id) == to_string(role_id)
      end) || socket.assigns[:selected_run]

    roles_map = socket.assigns[:roles_map] || %{}
    selected_role = resolve_role(role_id, roles_map)
    {log_lines, transcript} = load_run_transcript(selected_run)

    prev_run_id = socket.assigns[:subscribed_run_id]
    new_run_id = if selected_run, do: selected_run.id

    if connected?(socket) and new_run_id != prev_run_id do
      if prev_run_id, do: Phoenix.PubSub.unsubscribe(Rail.PubSub, "run:#{prev_run_id}")
      if new_run_id, do: Phoenix.PubSub.subscribe(Rail.PubSub, "run:#{new_run_id}")
    end

    socket =
      socket
      |> assign(:selected_role_id, role_id)
      |> assign(:selected_run, selected_run)
      |> assign(:selected_role, selected_role)
      |> assign(:log_lines, log_lines)
      |> assign(:transcript, transcript)
      |> assign(:subscribed_run_id, new_run_id)

    {:noreply, socket}
  end

  def handle_event("toggle_raw_log", _params, socket) do
    {:noreply, assign(socket, :show_raw_log, not socket.assigns.show_raw_log)}
  end

  def handle_event("toggle_activity", %{"index" => idx_val}, socket) do
    idx =
      case Integer.parse(to_string(idx_val)) do
        {num, _rem} -> num
        :error -> idx_val
      end

    current_expanded = socket.assigns[:expanded_activities] || MapSet.new()

    new_expanded =
      if MapSet.member?(current_expanded, idx) do
        MapSet.delete(current_expanded, idx)
      else
        MapSet.put(current_expanded, idx)
      end

    {:noreply, assign(socket, :expanded_activities, new_expanded)}
  end

  def handle_event("chat_input_change", %{"message" => message}, socket) do
    {:noreply, assign(socket, :chat_input, message)}
  end

  def handle_event("chat_input_change", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("send_chat", params, socket) do
    message = Map.get(params, "message") || socket.assigns[:chat_input] || ""
    trimmed = String.trim(message)
    role = socket.assigns[:selected_role]
    task = socket.assigns[:task]

    if trimmed == "" or socket.assigns[:chat_sending] or is_nil(role) or is_nil(task) do
      {:noreply, socket}
    else
      if task_has_live_run?(task) do
        modal = %{
          text: trimmed,
          role_id: role.id,
          role_name: role.name
        }

        {:noreply, assign(socket, :active_delivery_modal, modal)}
      else
        scope = socket.assigns.current_scope
        socket = assign(socket, :chat_sending, true)

        case Pipeline.send_chat_turn(scope, task.id, role.id, trimmed, delivery: :immediate) do
          {:error, _reason} ->
            {:noreply, assign(socket, :chat_sending, false)}

          _success ->
            socket =
              socket
              |> assign(:chat_sending, false)
              |> assign(:chat_input, "")
              |> refresh_task()

            {:noreply, socket}
        end
      end
    end
  end

  def handle_event("cancel_chat_delivery", _params, socket) do
    {:noreply, assign(socket, :active_delivery_modal, nil)}
  end

  def handle_event("confirm_chat_delivery", %{"delivery" => delivery_mode}, socket) do
    modal = socket.assigns[:active_delivery_modal]

    if is_nil(modal) do
      {:noreply, socket}
    else
      delivery_atom =
        case delivery_mode do
          "stop_and_send" -> :stop_and_send
          _other -> :when_finished
        end

      scope = socket.assigns.current_scope
      task = socket.assigns[:task]

      socket =
        socket
        |> assign(:active_delivery_modal, nil)
        |> assign(:chat_sending, true)

      case Pipeline.send_chat_turn(scope, task.id, modal.role_id, modal.text, delivery: delivery_atom) do
        {:error, _reason} ->
          {:noreply, assign(socket, :chat_sending, false)}

        _success ->
          socket =
            socket
            |> assign(:chat_sending, false)
            |> assign(:chat_input, "")
            |> refresh_task()

          {:noreply, socket}
      end
    end
  end

  def handle_event("stop_chat_turn", _params, socket) do
    scope = socket.assigns.current_scope
    task = socket.assigns[:task]

    if task do
      Pipeline.stop_chat_turn(scope, task.id)
    end

    {:noreply, refresh_task(socket)}
  end

  def handle_event("cancel_pending_chat", params, socket) do
    role_id =
      Map.get(params, "role_id") ||
        (socket.assigns[:selected_role] && socket.assigns.selected_role.id)

    scope = socket.assigns.current_scope
    task = socket.assigns[:task]

    if task && role_id do
      Pipeline.cancel_pending_chat(scope, task.id, role_id)
    end

    {:noreply, refresh_task(socket)}
  end

  def handle_event("refresh_diff", _params, socket) do
    {:noreply, do_load_diff(socket)}
  end

  def handle_event("toggle_viewed", %{"path" => path, "digest" => digest} = params, socket) do
    scope = socket.assigns.current_scope
    task = socket.assigns.task
    current_viewed = socket.assigns.viewed_diff_files || %{}

    new_state =
      case Map.get(params, "value") do
        "true" -> true
        "false" -> false
        _other -> not Map.has_key?(current_viewed, path)
      end

    {:ok, updated_task} = Pipeline.set_diff_file_viewed(scope, task, path, digest, new_state)

    socket =
      socket
      |> assign(:task, updated_task)
      |> assign(:viewed_diff_files, updated_task.viewed_diff_files || %{})

    {:noreply, socket}
  end

  def handle_event("expand_gap", params, socket) do
    path = params["path"]
    gap_index = String.to_integer(params["gap-index"] || params["gap_index"])
    start_line = String.to_integer(params["start-line"] || params["start_line"])
    end_line = String.to_integer(params["end-line"] || params["end_line"])

    {gap_key, lines} =
      Pipeline.expand_diff_gap(
        socket.assigns.task,
        path,
        gap_index,
        start_line,
        end_line,
        socket.assigns.diff_rev
      )

    expanded = Map.put(socket.assigns.expanded_gaps || %{}, gap_key, lines)
    {:noreply, assign(socket, :expanded_gaps, expanded)}
  end

  def handle_event("select_diff_file", %{"path" => path}, socket) do
    socket =
      socket
      |> assign(:selected_diff_file, path)
      |> push_event("scroll-to-file", %{path: path})

    {:noreply, socket}
  end

  def handle_event("rerecord_demo", params, socket) do
    handle_action_click("rerecord_demo", params, socket)
  end

  def handle_event("play_demo", params, socket) do
    demo = socket.assigns[:demo]

    if demo do
      seg_idx =
        case Map.get(params, "segment") do
          idx when is_integer(idx) ->
            idx

          idx when is_binary(idx) ->
            case Integer.parse(idx) do
              {parsed, _rest} -> parsed
              :error -> 0
            end

          _other ->
            0
        end

      player =
        demo
        |> DemoPlayerState.new(segment_index: seg_idx)
        |> DemoPlayerState.play()

      Process.send_after(self(), :demo_player_tick, 50)
      {:noreply, assign(socket, :demo_player, player)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("close_demo_player", _params, socket) do
    {:noreply, assign(socket, :demo_player, nil)}
  end

  def handle_event("player_toggle_play", _params, socket) do
    case socket.assigns[:demo_player] do
      %DemoPlayerState{} = player ->
        new_player = DemoPlayerState.toggle_play_pause(player)

        if new_player.is_playing do
          Process.send_after(self(), :demo_player_tick, 50)
        end

        {:noreply, assign(socket, :demo_player, new_player)}

      _other ->
        {:noreply, socket}
    end
  end

  def handle_event("player_next_frame", _params, socket) do
    case socket.assigns[:demo_player] do
      %DemoPlayerState{} = player ->
        {:noreply, assign(socket, :demo_player, DemoPlayerState.next_frame(player))}

      _other ->
        {:noreply, socket}
    end
  end

  def handle_event("player_prev_frame", _params, socket) do
    case socket.assigns[:demo_player] do
      %DemoPlayerState{} = player ->
        {:noreply, assign(socket, :demo_player, DemoPlayerState.prev_frame(player))}

      _other ->
        {:noreply, socket}
    end
  end

  def handle_event("player_next_segment", _params, socket) do
    case socket.assigns[:demo_player] do
      %DemoPlayerState{} = player ->
        {:noreply, assign(socket, :demo_player, DemoPlayerState.next_segment(player))}

      _other ->
        {:noreply, socket}
    end
  end

  def handle_event("player_prev_segment", _params, socket) do
    case socket.assigns[:demo_player] do
      %DemoPlayerState{} = player ->
        {:noreply, assign(socket, :demo_player, DemoPlayerState.prev_segment(player))}

      _other ->
        {:noreply, socket}
    end
  end

  def handle_event("player_seek", params, socket) do
    case socket.assigns[:demo_player] do
      %DemoPlayerState{} = player ->
        raw_ms = Map.get(params, "ms")

        ms =
          case raw_ms do
            i when is_integer(i) ->
              i

            s when is_binary(s) ->
              case Integer.parse(s) do
                {val, _rest} -> val
                :error -> 0
              end

            _other ->
              0
          end

        {:noreply, assign(socket, :demo_player, DemoPlayerState.seek(player, ms))}

      _other ->
        {:noreply, socket}
    end
  end

  def handle_event("player_toggle_loop", _params, socket) do
    case socket.assigns[:demo_player] do
      %DemoPlayerState{} = player ->
        {:noreply, assign(socket, :demo_player, DemoPlayerState.toggle_loop(player))}

      _other ->
        {:noreply, socket}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  def handle_info({:task_action_started, task_id, kind}, socket) do
    if socket.assigns[:task] && socket.assigns.task.id == task_id do
      socket =
        socket
        |> assign(:running_action, kind)
        |> assign(:task, %{socket.assigns.task | error: nil})

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:task_action_finished, task_id, _kind}, socket) do
    if socket.assigns[:task] && socket.assigns.task.id == task_id do
      socket =
        socket
        |> assign(:running_action, nil)
        |> refresh_task()

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:pipeline_changed, %{task_id: task_id}}, socket) do
    if socket.assigns[:task] && socket.assigns.task.id == task_id do
      {:noreply, refresh_task(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:livesync, :tasks, _table, _event, record}, socket) do
    target_id =
      cond do
        is_map(record) and Map.has_key?(record, :id) -> record.id
        is_map(record) and Map.has_key?(record, "id") -> record["id"]
        true -> nil
      end

    if socket.assigns[:task] && socket.assigns.task.id == target_id do
      {:noreply, refresh_task(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:run_events, run_id, events}, socket) do
    if socket.assigns[:selected_run] && socket.assigns.selected_run.id == run_id do
      new_lines = Enum.map(events, & &1.line)
      all_lines = socket.assigns.log_lines ++ new_lines
      transcript = ChatTranscript.parse(all_lines)

      socket =
        socket
        |> assign(:log_lines, all_lines)
        |> assign(:transcript, transcript)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  # Private Helpers
  def handle_info({:os_process_finished, _run, _outcome}, socket) do
    {:noreply, refresh_task(socket)}
  end

  def handle_info({:task_updated, updated_task}, socket) do
    if socket.assigns[:task] && socket.assigns.task.id == updated_task.id do
      {:noreply, apply_task_update(socket, updated_task)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(:demo_player_tick, socket) do
    case socket.assigns[:demo_player] do
      %DemoPlayerState{is_playing: true} = player ->
        new_player = DemoPlayerState.tick(player, 50)

        if new_player.is_playing do
          Process.send_after(self(), :demo_player_tick, 50)
        end

        {:noreply, assign(socket, :demo_player, new_player)}

      _other ->
        {:noreply, socket}
    end
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  def handle_async({:task_action, _kind}, {:ok, _result}, socket) do
    socket =
      socket
      |> assign(:running_action, nil)
      |> refresh_task()

    {:noreply, socket}
  end

  def handle_async({:task_action, kind}, {:exit, reason}, socket) do
    if socket.assigns[:task] do
      TaskActionRunner.finish_action(socket.assigns.task.id, kind, {:error, reason})
    end

    socket =
      socket
      |> assign(:running_action, nil)
      |> refresh_task()

    {:noreply, socket}
  end

  def handle_async(_name, _result, socket), do: {:noreply, socket}

  def terminate(_reason, _socket), do: :ok

  defp parse_tab("overview"), do: :overview
  defp parse_tab("plan"), do: :plan
  defp parse_tab("conversation"), do: :conversation
  defp parse_tab("diff"), do: :diff
  defp parse_tab(_other), do: :overview

  defp handle_action_click("chat", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/tasks/#{socket.assigns.task.id}?tab=conversation")}
  end

  defp handle_action_click("diff", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/tasks/#{socket.assigns.task.id}?tab=diff")}
  end

  defp handle_action_click("merge", params, socket) do
    ignore_conflicts = params["ignore_conflicts"] == "true"
    {:noreply, assign(socket, :active_modal, %{type: :confirm_merge, ignore_conflicts: ignore_conflicts})}
  end

  defp handle_action_click("rebase", _params, socket) do
    {:noreply, assign(socket, :active_modal, %{type: :confirm_rebase})}
  end

  defp handle_action_click("cleanup", _params, socket) do
    if task_busy?(socket.assigns.task, socket.assigns.running_action) do
      {:noreply, socket}
    else
      {:noreply, assign(socket, :active_modal, %{type: :confirm_cleanup})}
    end
  end

  defp handle_action_click("comment", _params, socket) do
    role_name = socket.assigns[:current_role_name]
    {:noreply, assign(socket, :active_modal, %{type: :prompt_send_back, role_name: role_name})}
  end

  defp handle_action_click("send_back_to_engineer", _params, socket) do
    {:noreply, assign(socket, :active_modal, %{type: :prompt_send_back_to_engineer})}
  end

  defp handle_action_click("decline_demo", _params, socket) do
    {:noreply, assign(socket, :active_modal, %{type: :prompt_decline_demo})}
  end

  defp handle_action_click("approve", _params, socket) do
    scope = socket.assigns.current_scope
    task = socket.assigns.task
    execute_action(socket, :approve, fn -> Pipeline.approve_stage(scope, task) end)
  end

  defp handle_action_click("approve_skip_design", _params, socket) do
    scope = socket.assigns.current_scope
    task = socket.assigns.task
    execute_action(socket, :approve, fn -> Pipeline.approve_stage(scope, task, skip_design: true) end)
  end

  defp handle_action_click("pick_design_direction", params, socket) do
    direction_key = params["direction_key"]
    scope = socket.assigns.current_scope
    task = socket.assigns.task
    execute_action(socket, :pick_design_direction, fn -> Pipeline.pick_design_direction(scope, task, direction_key) end)
  end

  defp handle_action_click("skip", _params, socket) do
    scope = socket.assigns.current_scope
    task = socket.assigns.task
    execute_action(socket, :skip, fn -> Pipeline.skip_to_ready_to_merge(scope, task) end)
  end

  defp handle_action_click("retry", _params, socket) do
    scope = socket.assigns.current_scope
    task = socket.assigns.task
    execute_action(socket, :retry, fn -> Pipeline.retry_stage(scope, task) end)
  end

  defp handle_action_click("rerecord_demo", _params, socket) do
    scope = socket.assigns.current_scope
    task = socket.assigns.task
    execute_action(socket, :rerecord_demo, fn -> Pipeline.rerecord_demo(scope, task) end)
  end

  defp handle_action_click("recheck_design", _params, socket) do
    scope = socket.assigns.current_scope
    task = socket.assigns.task
    execute_action(socket, :recheck_design, fn -> Pipeline.recheck_design(scope, task) end)
  end

  defp handle_action_click("cancel", _params, socket) do
    scope = socket.assigns.current_scope
    task = socket.assigns.task
    execute_action(socket, :cancel, fn -> Pipeline.cancel_task(scope, task) end)
  end

  defp handle_action_click("dispatch", _params, socket) do
    scope = socket.assigns.current_scope
    task = socket.assigns.task
    execute_action(socket, :dispatch, fn -> Pipeline.dispatch_now(scope, task) end)
  end

  defp handle_action_click("unblock", _params, socket) do
    scope = socket.assigns.current_scope
    task = socket.assigns.task
    execute_action(socket, :unblock, fn -> Pipeline.release_blocked_stage(scope, task) end)
  end

  defp handle_action_click("mark_ready", _params, socket) do
    scope = socket.assigns.current_scope
    task = socket.assigns.task
    execute_action(socket, :mark_ready, fn -> Pipeline.mark_pr_ready(scope, task) end)
  end

  defp handle_action_click(_action, _params, socket), do: {:noreply, socket}

  defp handle_submit_modal("merge", params, socket) do
    ignore_conflicts = params["ignore_conflicts"] == "true"
    scope = socket.assigns.current_scope
    task = socket.assigns.task

    socket
    |> assign(:active_modal, nil)
    |> execute_action(:merge, fn ->
      Pipeline.merge_task(scope, task, ignore_conflicts: ignore_conflicts)
    end)
  end

  defp handle_submit_modal("rebase", _params, socket) do
    scope = socket.assigns.current_scope
    task = socket.assigns.task

    socket
    |> assign(:active_modal, nil)
    |> execute_action(:rebase, fn ->
      Pipeline.start_rebase(scope, task)
    end)
  end

  defp handle_submit_modal("cleanup", _params, socket) do
    if task_busy?(socket.assigns.task, socket.assigns.running_action) do
      {:noreply, assign(socket, :active_modal, nil)}
    else
      scope = socket.assigns.current_scope
      task = socket.assigns.task

      socket
      |> assign(:active_modal, nil)
      |> execute_action(:cleanup, fn ->
        Pipeline.cleanup_task(scope, task)
      end)
    end
  end

  defp handle_submit_modal("comment", params, socket) do
    comment = params["comment"]
    trimmed = if is_binary(comment), do: String.trim(comment), else: ""

    if trimmed == "" do
      {:noreply, socket}
    else
      scope = socket.assigns.current_scope
      task = socket.assigns.task

      socket
      |> assign(:active_modal, nil)
      |> execute_action(:comment, fn ->
        Pipeline.request_changes(scope, task, trimmed)
      end)
    end
  end

  defp handle_submit_modal("send_back_to_engineer", params, socket) do
    comment = params["comment"]
    trimmed = if is_binary(comment), do: String.trim(comment), else: ""
    opts = if trimmed == "", do: [], else: [comment: trimmed]
    scope = socket.assigns.current_scope
    task = socket.assigns.task

    socket
    |> assign(:active_modal, nil)
    |> execute_action(:send_back_to_engineer, fn ->
      Pipeline.send_back_to_engineer(scope, task, opts)
    end)
  end

  defp handle_submit_modal("decline_demo", params, socket) do
    reason = params["reason"]
    trimmed = if is_binary(reason) and String.trim(reason) != "", do: String.trim(reason), else: "Declined by human"
    scope = socket.assigns.current_scope
    task = socket.assigns.task

    socket
    |> assign(:active_modal, nil)
    |> execute_action(:decline_demo, fn ->
      Pipeline.decline_demo(scope, task, trimmed)
    end)
  end

  defp handle_submit_modal(_action, _params, socket), do: {:noreply, socket}

  defp execute_action(socket, kind, work_fn, opts \\ []) do
    task = socket.assigns[:task]

    if is_nil(task) or socket.assigns[:running_action] != nil do
      {:noreply, socket}
    else
      task_id = task.id

      socket =
        socket
        |> assign(:running_action, kind)
        |> assign(:task, %{task | error: nil})

      socket =
        start_async(socket, {:task_action, kind}, fn ->
          TaskActionRunner.run(task_id, kind, work_fn, opts)
        end)

      {:noreply, socket}
    end
  end

  defp task_busy?(task, running_action) do
    running_action != nil or
      (is_struct(task) and (task.stage_state in [:running, :rebasing] or task.is_rebasing == true))
  end

  defp resolve_current_run(%Task{} = task) do
    run = if is_list(task.runs) and task.runs != [], do: List.last(task.runs)

    role_id =
      cond do
        run != nil and run.role_id != nil -> run.role_id
        task.active_chat_role_id != nil -> task.active_chat_role_id
        true -> task.stage
      end

    {run, RailWeb.Components.StageOutcome.format_role_id(role_id)}
  end

  defp branch_name_for(%Task{worktree_name: "rail/" <> _ = name}), do: name
  defp branch_name_for(%Task{worktree_name: name}), do: "rail/#{name}"

  defp issue_identifier_for(task) do
    if is_map(task.issue), do: task.issue.identifier
  end

  defp pr_url_for(task) do
    if is_binary(task.pr_url) and task.pr_url != "" do
      task.pr_url
    else
      repo = if is_map(task.project), do: task.project.github_repo

      if is_binary(repo) and repo != "" do
        "https://github.com/#{repo}/pull/#{task.pr_number}"
      else
        "#"
      end
    end
  end

  defp task_priority_label(task) do
    priority = if is_map(task.issue), do: task.issue.priority, else: :medium
    Issue.priority_label(priority || :medium) || "Medium"
  end

  defp refresh_task(socket) do
    case Pipeline.get_task(socket.assigns.current_scope, socket.assigns.task_id) do
      {:ok, task} -> apply_task_data(socket, task)
      {:error, _reason} -> assign(socket, :task, nil)
    end
  end

  defp apply_task_update(socket, task) do
    apply_task_data(socket, task)
  end

  defp apply_task_data(socket, task) do
    scope = socket.assigns.current_scope
    {current_run, role_name} = resolve_current_run(task)

    design =
      task.design ||
        if(is_list(task.designs) and task.designs != [], do: List.last(task.designs))

    demo =
      task.demo ||
        if(is_list(task.demos) and task.demos != [], do: List.last(task.demos))

    running_action = socket.assigns[:running_action] || TaskActionRunner.running_on(task.id)
    pending_questions = resolve_pending_questions(scope, task)
    pending_question = select_pending_question(pending_questions, socket.assigns[:selected_question_id])
    selected_question_id = question_id(pending_question)

    roles = if task.project_id, do: Rail.Roles.list_roles(scope, task.project_id), else: []
    roles_map = Map.new(roles, fn r -> {r.id, r} end)

    ordered_runs = sort_runs(task.runs || [])
    selected_role_id = resolve_selected_role_id(ordered_runs, socket.assigns[:selected_role_id])
    selected_run = find_selected_run(ordered_runs, selected_role_id)
    selected_role = if selected_role_id, do: resolve_role(selected_role_id, roles_map)

    {log_lines, transcript} = load_run_transcript(selected_run)

    prev_run_id = socket.assigns[:subscribed_run_id]
    new_run_id = if selected_run, do: selected_run.id
    sync_run_pubsub(socket, prev_run_id, new_run_id)

    socket
    |> assign(:task, task)
    |> assign(:task_id, task.id)
    |> assign(:page_title, task.issue && task.issue.title)
    |> assign(:project_id, task.project_id)
    |> assign(:current_project_id, task.project_id)
    |> assign(:current_run, current_run)
    |> assign(:current_role_name, role_name)
    |> assign(:runs, task.runs || [])
    |> assign(:running_action, running_action)
    |> assign(:design, design)
    |> assign(:demo, demo)
    |> assign(:ticket_content, Formatters.ticket_for(task))
    |> assign(:plan_content, Formatters.plan_for(task))
    |> assign(:pending_question, pending_question)
    |> assign(:pending_questions, pending_questions)
    |> assign(:selected_question_id, selected_question_id)
    |> assign(:roles_map, roles_map)
    |> assign(:ordered_runs, ordered_runs)
    |> assign(:selected_role_id, selected_role_id)
    |> assign(:selected_run, selected_run)
    |> assign(:selected_role, selected_role)
    |> assign(:log_lines, log_lines)
    |> assign(:transcript, transcript)
    |> assign(:subscribed_run_id, new_run_id)
    |> assign(:viewed_diff_files, task.viewed_diff_files || %{})
  end

  # A run can ask several things at once, so a blocked task shows the whole queue as
  # tabs. task.question_id only names the one the pipeline parks on.
  defp resolve_pending_questions(scope, %{stage_state: :blocked, id: task_id}) do
    Pipeline.list_pending_questions(scope, task_id, order_by: [asc: :inserted_at, asc: :id])
  end

  defp resolve_pending_questions(_scope, _task), do: []

  # The tab the human picked stays put across refreshes; once it is answered the
  # front of the queue takes over.
  defp select_pending_question(questions, selected_id) do
    Enum.find(questions, &(&1.id == selected_id)) || List.first(questions)
  end

  defp question_id(%{id: id}), do: id
  defp question_id(_none), do: nil

  defp resolve_selected_role_id(ordered_runs, current_selected_role_id) do
    cond do
      current_selected_role_id &&
          Enum.any?(ordered_runs, fn r ->
            r.role_id == current_selected_role_id or
                to_string(r.role_id) == to_string(current_selected_role_id)
          end) ->
        current_selected_role_id

      ordered_runs != [] ->
        List.last(ordered_runs).role_id

      true ->
        nil
    end
  end

  defp find_selected_run(ordered_runs, selected_role_id) do
    if selected_role_id do
      Enum.find(ordered_runs, fn r ->
        r.role_id == selected_role_id or to_string(r.role_id) == to_string(selected_role_id)
      end) || List.last(ordered_runs)
    else
      List.last(ordered_runs)
    end
  end

  defp sync_run_pubsub(socket, prev_run_id, new_run_id) do
    if connected?(socket) and new_run_id != prev_run_id do
      if prev_run_id, do: Phoenix.PubSub.unsubscribe(Rail.PubSub, "run:#{prev_run_id}")
      if new_run_id, do: Phoenix.PubSub.subscribe(Rail.PubSub, "run:#{new_run_id}")
    end
  end

  defp task_has_live_run?(task) do
    is_struct(task) and
      (task.stage_state in [:running, :rebasing] or task.is_rebasing == true or
         Runs.running?(task.id))
  end

  defp load_run_transcript(%Run{id: run_id}) do
    lines = run_id |> Runs.list_run_events() |> Enum.map(& &1.line)

    {lines, ChatTranscript.parse(lines)}
  end

  defp load_run_transcript(_other), do: {[], ChatTranscript.parse([])}

  defp sort_runs(runs) do
    Enum.sort_by(runs, fn r ->
      {r.started_at || ~U[1970-01-01 00:00:00Z], r.inserted_at || ~U[1970-01-01 00:00:00Z], r.id || ""}
    end)
  end

  defp resolve_role(role_id, roles_map) do
    if is_map(roles_map) and Map.has_key?(roles_map, role_id) do
      role = Map.get(roles_map, role_id)
      %{id: role_id, name: role.name, icon_name: Map.get(role, :icon_name, "pi-terminal-window")}
    else
      %{id: role_id, name: format_role_id(role_id), icon_name: "pi-terminal-window"}
    end
  end

  defp format_role_id(role_id) do
    role_id
    |> to_string()
    |> String.split("_")
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp maybe_load_diff(socket, :diff) do
    task = socket.assigns.task

    if task && Task.worktree_present?(task) && socket.assigns.file_diffs == [] &&
         not socket.assigns.loading_diff do
      do_load_diff(socket)
    else
      socket
    end
  end

  defp maybe_load_diff(socket, _other_tab), do: socket

  defp do_load_diff(socket) do
    task = socket.assigns.task

    case Pipeline.load_diff(task) do
      {:ok, parsed_files, diff_rev} ->
        task = Pipeline.get_task!(socket.assigns.current_scope, task.id)

        socket
        |> assign(:file_diffs, parsed_files)
        |> assign(:diff_rev, diff_rev)
        |> assign(:viewed_diff_files, task.viewed_diff_files || %{})
        |> assign(:expanded_gaps, %{})
        |> assign(:loading_diff, false)

      {:error, _reason} ->
        socket
        |> assign(:file_diffs, [])
        |> assign(:diff_rev, nil)
        |> assign(:loading_diff, false)
    end
  end
end
