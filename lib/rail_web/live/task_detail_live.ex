defmodule RailWeb.TaskDetailLive do
  @moduledoc false
  use RailWeb, :live_view

  import RailWeb.CoreComponents,
    only: [
      icon: 1,
      project_badge: 1,
      stage_stepper: 1,
      stage_outcome: 1,
      markdown: 1
    ]

  alias Rail.Domain.Enums.TaskPriority
  alias Rail.Domain.Formatters
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task

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
      |> assign(:role_runs, [])
      |> assign(:ticket_content, "")
      |> assign(:plan_content, nil)

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
            end

            {current_run, role_name} = resolve_current_run(task)

            socket
            |> assign(:task, task)
            |> assign(:task_id, task.id)
            |> assign(:page_title, task.title)
            |> assign(:project_id, task.project_id)
            |> assign(:current_project_id, task.project_id)
            |> assign(:current_run, current_run)
            |> assign(:current_role_name, role_name)
            |> assign(:role_runs, task.role_runs || [])
            |> assign(:ticket_content, Formatters.ticket_for(task))
            |> assign(:plan_content, Formatters.plan_for(task))

          {:error, _reason} ->
            socket
            |> assign(:task, nil)
            |> assign(:task_id, task_id)
            |> assign(:page_title, "Task")
            |> assign(:current_run, nil)
            |> assign(:current_role_name, nil)
            |> assign(:role_runs, [])
            |> assign(:ticket_content, "")
            |> assign(:plan_content, nil)
        end
      else
        socket
      end

    active_tab = parse_tab(Map.get(params, "tab"))

    socket =
      socket
      |> assign(:active_tab, active_tab)
      |> assign(:current_section, :tasks)

    {:noreply, socket}
  end

  def render(assigns) do
    ~H"""
    <div id="task-detail-view" data-qa="task-detail-view" class="space-y-6">
      <%= if is_nil(@task) do %>
        <!-- Deleted / Cleaned Up State -->
        <div class="flex items-center justify-between" id="task-detail-header">
          <h1
            class="text-2xl font-bold tracking-tight text-[var(--color-on-surface)]"
            id="task-detail-title"
            data-qa="task_detail_title"
          >
            Task
          </h1>
        </div>

        <div
          id="task-cleaned-up"
          data-qa="task-cleaned-up"
          class="flex flex-col items-center justify-center min-h-[300px] text-center p-8 bg-[var(--color-surface)] rounded-xl border border-[var(--color-border)] shadow-xs"
        >
          <p class="text-base font-medium text-[var(--color-outline)]">
            This task has been cleaned up.
          </p>
        </div>
      <% else %>
        <!-- Task Header with Project Badge, Title & 4 Tabs in exact order -->
        <div class="space-y-4 border-b border-[var(--color-border)] pb-0">
          <div class="flex items-center gap-3">
            <.project_badge project={@task.project} />
            <h1
              class="text-2xl font-bold tracking-tight text-[var(--color-on-surface)] truncate"
              id="task-detail-title"
              data-qa="task_detail_title"
              title={@task.title}
            >
              {@task.title}
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
              data-qa="tab_overview"
              data-active={if @active_tab == :overview, do: "true", else: "false"}
              class={[
                "pb-3 border-b-2 transition-colors cursor-pointer",
                @active_tab == :overview &&
                  "border-[var(--color-primary)] text-[var(--color-primary)] font-bold",
                @active_tab != :overview &&
                  "border-transparent text-[var(--color-outline)] hover:text-[var(--color-on-surface)] hover:border-[var(--color-outline-variant)]"
              ]}
            >
              Overview
            </.link>

            <.link
              patch={~p"/tasks/#{@task.id}?tab=plan"}
              id="tab-plan"
              data-qa="tab_plan"
              data-active={if @active_tab == :plan, do: "true", else: "false"}
              class={[
                "pb-3 border-b-2 transition-colors cursor-pointer",
                @active_tab == :plan &&
                  "border-[var(--color-primary)] text-[var(--color-primary)] font-bold",
                @active_tab != :plan &&
                  "border-transparent text-[var(--color-outline)] hover:text-[var(--color-on-surface)] hover:border-[var(--color-outline-variant)]"
              ]}
            >
              Plan
            </.link>

            <.link
              patch={~p"/tasks/#{@task.id}?tab=conversation"}
              id="tab-conversation"
              data-qa="tab_conversation"
              data-active={if @active_tab == :conversation, do: "true", else: "false"}
              class={[
                "pb-3 border-b-2 transition-colors cursor-pointer",
                @active_tab == :conversation &&
                  "border-[var(--color-primary)] text-[var(--color-primary)] font-bold",
                @active_tab != :conversation &&
                  "border-transparent text-[var(--color-outline)] hover:text-[var(--color-on-surface)] hover:border-[var(--color-outline-variant)]"
              ]}
            >
              Conversation
            </.link>

            <.link
              patch={~p"/tasks/#{@task.id}?tab=diff"}
              id="tab-diff"
              data-qa="tab_diff"
              data-active={if @active_tab == :diff, do: "true", else: "false"}
              class={[
                "pb-3 border-b-2 transition-colors cursor-pointer",
                @active_tab == :diff &&
                  "border-[var(--color-primary)] text-[var(--color-primary)] font-bold",
                @active_tab != :diff &&
                  "border-transparent text-[var(--color-outline)] hover:text-[var(--color-on-surface)] hover:border-[var(--color-outline-variant)]"
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
          <.stage_stepper task={@task} role_runs={@role_runs} />

          <!-- Metadata Wrap -->
          <div
            id="task-metadata-wrap"
            data-qa="task-metadata-wrap"
            class="flex flex-wrap items-center gap-4 py-2 text-xs text-[var(--color-outline)]"
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
              :if={branch_name_for(@task)}
              id="meta-branch"
              data-qa="meta-branch"
              class="flex items-center gap-1.5 shrink-0 font-mono"
            >
              <.icon name="account_tree_outlined" class="h-4 w-4 shrink-0" />
              <span>{branch_name_for(@task)}</span>
            </div>

            <!-- Issue Meta -->
            <div
              :if={issue_identifier_for(@task)}
              id="meta-issue"
              data-qa="meta-issue"
              class="flex items-center gap-1.5 shrink-0"
            >
              <.icon name="lightbulb_outline" class="h-4 w-4 shrink-0" />
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
              class="inline-flex items-center gap-1 text-[var(--color-primary)] hover:underline shrink-0 font-semibold"
            >
              <.icon name="merge_type" class="h-4 w-4 shrink-0" />
              <span>{"PR ##{@task.pr_number}"}</span>
              <.icon name="open_in_new" class="h-3.5 w-3.5 shrink-0" />
            </a>

            <!-- Priority Meta -->
            <div
              id="meta-priority"
              data-qa="meta-priority"
              class="flex items-center gap-1.5 shrink-0"
            >
              <.icon name="flag_outlined" class="h-4 w-4 shrink-0" />
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
              <.icon name="call_split" class="h-5 w-5 shrink-0 mt-0.5" />
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
            class="p-4 rounded-xl bg-[var(--color-error-container)] border border-[var(--color-error)] text-[var(--color-on-error-container)]"
          >
            <p class="text-xs font-mono whitespace-pre-wrap leading-relaxed">{@task.error}</p>
          </div>

          <!-- Stage Outcome Component -->
          <.stage_outcome
            task={@task}
            role_run={@current_run}
            role_name={@current_role_name}
          />

          <!-- Ticket Section (Always Last on Overview) -->
          <div id="ticket-section" data-qa="ticket_section" class="space-y-2 pt-2">
            <h3 class="text-base font-bold text-[var(--color-on-surface)]">
              Ticket
            </h3>
            <div class="m3-card p-4 select-text">
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
              class="flex items-center justify-center min-h-[300px] text-center p-8 bg-[var(--color-surface)] rounded-xl border border-[var(--color-border)] shadow-xs"
            >
              <p class="text-sm font-medium text-[var(--color-outline)]">
                No plan has been written yet.
              </p>
            </div>
          <% else %>
            <div id="plan-content" data-qa="plan_content" class="space-y-4">
              <div class="m3-card p-6 select-text">
                <.markdown content={@plan_content} />
              </div>
            </div>
          <% end %>
        </div>

        <!-- Tab 3: Conversation Pane (Stub placeholder for 6.3) -->
        <div
          id="tab-conversation-pane"
          data-qa="tab-conversation-pane"
          class={[@active_tab != :conversation && "hidden"]}
        >
          <div
            id="conversation-empty-state"
            data-qa="conversation_empty_state"
            class="flex items-center justify-center min-h-[300px] text-center p-8 bg-[var(--color-surface)] rounded-xl border border-[var(--color-border)] shadow-xs"
          >
            <p class="text-sm font-medium text-[var(--color-outline)]">
              No role has run this task yet.
            </p>
          </div>
        </div>

        <!-- Tab 4: Diff Pane (Stub placeholder for 6.4) -->
        <div
          id="tab-diff-pane"
          data-qa="tab-diff-pane"
          class={[@active_tab != :diff && "hidden"]}
        >
          <%= if is_nil(@task.worktree_path) do %>
            <div
              id="diff-empty-state"
              data-qa="diff_empty_state"
              class="flex items-center justify-center min-h-[300px] text-center p-8 bg-[var(--color-surface)] rounded-xl border border-[var(--color-border)] shadow-xs"
            >
              <p class="text-sm font-medium text-[var(--color-outline)]">
                This task has no worktree.
              </p>
            </div>
          <% else %>
            <div
              id="diff-stub-content"
              data-qa="diff_stub_content"
              class="p-6 bg-[var(--color-surface)] rounded-xl border border-[var(--color-border)]"
            >
              <p class="text-xs font-mono text-[var(--color-outline)]">
                Worktree: {@task.worktree_path}
              </p>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    if socket.assigns[:task] do
      {:noreply, push_patch(socket, to: ~p"/tasks/#{socket.assigns.task.id}?tab=#{tab}")}
    else
      {:noreply, socket}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

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

  def handle_info({:task_updated, updated_task}, socket) do
    if socket.assigns[:task] && socket.assigns.task.id == updated_task.id do
      {:noreply, apply_task_update(socket, updated_task)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  def handle_async(_name, _result, socket), do: {:noreply, socket}

  def terminate(_reason, _socket), do: :ok

  # Private Helpers

  defp parse_tab("overview"), do: :overview
  defp parse_tab("plan"), do: :plan
  defp parse_tab("conversation"), do: :conversation
  defp parse_tab("diff"), do: :diff
  defp parse_tab(_other), do: :overview

  defp resolve_current_run(%Task{} = task) do
    run = if is_list(task.role_runs) and task.role_runs != [], do: List.last(task.role_runs)

    role_id =
      cond do
        run != nil and run.role_id != nil -> run.role_id
        task.active_chat_role_id != nil -> task.active_chat_role_id
        true -> task.stage
      end

    {run, RailWeb.Components.StageOutcome.format_role_id(role_id)}
  end

  defp branch_name_for(task) do
    cond do
      is_binary(task.worktree_name) and task.worktree_name != "" ->
        if String.starts_with?(task.worktree_name, "axis/") do
          task.worktree_name
        else
          "axis/#{task.worktree_name}"
        end

      is_map(task.issue) and is_binary(task.issue.branch_name) and task.issue.branch_name != "" ->
        task.issue.branch_name

      true ->
        nil
    end
  end

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
    TaskPriority.label(priority || :medium) || "Medium"
  end

  defp refresh_task(socket) do
    case Pipeline.get_task(socket.assigns.current_scope, socket.assigns.task_id) do
      {:ok, task} -> apply_task_update(socket, task)
      {:error, _reason} -> assign(socket, :task, nil)
    end
  end

  defp apply_task_update(socket, task) do
    {current_run, role_name} = resolve_current_run(task)

    socket
    |> assign(:task, task)
    |> assign(:page_title, task.title)
    |> assign(:current_run, current_run)
    |> assign(:current_role_name, role_name)
    |> assign(:ticket_content, Formatters.ticket_for(task))
    |> assign(:plan_content, Formatters.plan_for(task))
  end
end
