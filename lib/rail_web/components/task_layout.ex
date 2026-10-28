defmodule RailWeb.Components.TaskLayout do
  @moduledoc """
  The frame the task page sits in: a header across the top with every decision a person makes on the task, and
  the task's items below it.
  """
  use RailWeb, :html

  import RailWeb.Utils.StageLabel, only: [ready_to_merge?: 2, review_waiting?: 2]

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Workflows.Schemas.Workflow

  attr :task, :any, required: true
  attr :run, :any, default: nil
  # The status reads the task's stage, whichever tab is open; nil when that stage has no run yet.
  attr :stage_run, :any, required: true
  # What that run waits on: its place in the line for a sandbox, or `Rail.Tools.get_usage_wait/1`.
  attr :line, :map, default: nil
  attr :title, :string, default: nil
  attr :flush, :boolean, default: false
  # Said in place of the stage, `%{label:, icon:, class:}`, by a split parent or a child waiting on its
  # siblings, neither of which has a branch to show yet.
  attr :status, :map, default: nil
  # Only admins can follow the workflow's name to Settings > Workflows.
  attr :link_workflow, :boolean, default: false

  slot :breadcrumb
  slot :meta
  slot :actions
  slot :alerts
  slot :inner_block

  def task_layout(assigns) do
    assigns =
      assigns
      |> assign(:sandbox_line, if(is_map_key(assigns.line || %{}, :position), do: assigns.line))
      |> assign(:starts_at, if(is_map_key(assigns.line || %{}, :accounts), do: assigns.line.resets_at))
      |> assign(:workflow, if(match?(%Workflow{}, assigns.task.issue.workflow), do: assigns.task.issue.workflow))

    ~H"""
    <div class="-m-6 h-[calc(100%+3rem)] flex flex-col min-h-0">
      <div
        id="task-header"
        data-qa="task-header"
        class="px-6 py-4 space-y-2 border-b border-slate-200 dark:border-slate-700"
      >
        {render_slot(@breadcrumb)}

        <div class="flex items-center gap-3 min-w-0">
          <.project_badge project={@task.project} />
          <h1
            class="text-2xl font-bold tracking-tight text-slate-900 dark:text-slate-100 truncate"
            id="task-detail-title"
            data-qa="task_detail_title"
          >
            {@title}
          </h1>
        </div>

        <div class="flex items-center flex-wrap gap-x-4 gap-y-2 text-sm text-slate-500 dark:text-slate-400">
          <span
            :if={@status}
            id="task-status-chip"
            data-qa="task_status_chip"
            class={["inline-flex items-center gap-1.5 font-semibold", @status.class]}
          >
            <.icon name={@status.icon} class="h-4 w-4" />
            {@status.label}
          </span>
          <span
            :if={!@status}
            id="task-status-chip"
            data-qa="task_status_chip"
            class={[
              "inline-flex items-center gap-1.5 font-semibold",
              chip_style(@task, @stage_run).text_class
            ]}
          >
            <.icon
              :if={
                @line != nil or ready_to_merge?(@task, @stage_run) or
                  review_waiting?(@task, @stage_run) or @task.stage in [:finalize, :merged] or
                  (@task.stage == :custom and Run.state(@stage_run) == :stopped)
              }
              name={chip_style(@task, @stage_run).icon}
              class={[
                "h-4 w-4",
                (@task.stage == :finalize and Task.finalize_state(@task) == :merging) &&
                  "motion-safe:animate-spin"
              ]}
            />
            {stage_label(@task, @stage_run)}
            <span :if={@starts_at} id="task-usage-starts" data-qa="task_usage_starts">
              · starts <.local_time id="task-usage-starts-at" at={@starts_at} />
            </span>
          </span>

          <a
            :if={@task.issue.url not in [nil, ""]}
            href={@task.issue.url}
            target="_blank"
            rel="noopener noreferrer"
            id="task-issue-link"
            data-qa="task_issue_identifier"
            title={"Open #{@task.issue.identifier} in #{Issue.tracker_label(@task.issue.tracker)}"}
            class="inline-flex items-center gap-1 font-mono text-blue-600 dark:text-blue-400 hover:underline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500 rounded-sm"
          >
            <.icon name="pi-ticket" class="size-4" />{@task.issue.identifier}
          </a>
          <span
            :if={@task.issue.url in [nil, ""]}
            id="task-issue-identifier"
            data-qa="task_issue_identifier"
            class="font-mono"
          >
            {@task.issue.identifier}
          </span>
          <span
            :if={!@status}
            data-qa="task_branch_name"
            class="font-mono truncate min-w-0 max-w-[26rem]"
            title={@task.worktree_name}
          >
            {@task.worktree_name}
          </span>
          <a
            :if={@task.pr_url}
            href={@task.pr_url}
            target="_blank"
            rel="noopener noreferrer"
            id="task-pull-request"
            data-qa="task_pull_request"
            class="inline-flex items-center gap-1 font-mono text-blue-600 dark:text-blue-400 hover:underline"
          >
            <.icon name="pi-git-pull-request" class="size-4" /> PR #{@task.pr_number}
          </a>

          <span
            :if={@workflow}
            id="task-workflow"
            data-qa="task_workflow"
            class="inline-flex flex-wrap items-center gap-x-1.5 min-w-0"
          >
            <.icon name="pi-repeat" class="size-4 shrink-0" />
            <.link
              :if={@link_workflow}
              navigate={~p"/settings/workflows"}
              id="task-workflow-link"
              title="Settings › Workflows"
              class="font-medium text-slate-700 dark:text-slate-200 underline decoration-slate-400 dark:decoration-slate-600 underline-offset-2 hover:decoration-slate-300 focus-visible:outline-2 focus-visible:outline-indigo-500 rounded wrap-break-word min-w-0"
            >
              {Workflow.name(@workflow)}
            </.link>
            <span
              :if={!@link_workflow}
              id="task-workflow-name"
              class="font-medium text-slate-700 dark:text-slate-200 wrap-break-word min-w-0"
            >
              {Workflow.name(@workflow)}
            </span>
            <.stage_sequence
              id="task-stage-sequence"
              skipped={@task.issue.skipped_steps}
              stages={@task.issue.stages}
              layout={:inline}
            />
          </span>

          <.link
            :if={@sandbox_line}
            navigate={~p"/sandboxes"}
            id="task-line"
            data-qa="task_line"
            class="inline-flex items-center gap-1 text-blue-600 dark:text-blue-400 hover:underline"
          >
            <.icon name="pi-cube" class="size-4" />
            {format_ordinal(@sandbox_line.position)} in line for {format_reservation(
              @sandbox_line.os_process
            )}
          </.link>

          {render_slot(@meta)}

          <div class="ml-auto flex items-center flex-wrap gap-2">
            {render_slot(@actions)}
          </div>
        </div>

        {render_slot(@alerts)}

        <p
          :if={@run != nil and is_binary(@run.error)}
          id="task-error-card"
          data-qa="task_error_card"
          class="rounded-xl border border-red-200 bg-red-50 dark:border-red-900 dark:bg-red-950 p-3 text-xs text-red-700 dark:text-red-300"
        >
          {@run.error}
        </p>
      </div>

      <div class="flex flex-col lg:flex-row flex-1 min-h-0">
        <!-- A pane that scrolls its own panels wants the column, not a gutter. -->
        <div
          id="task-main-column"
          class={[
            "flex-1 min-w-0 min-h-0",
            @flush && "overflow-hidden",
            not @flush && "overflow-y-auto px-6 py-8"
          ]}
        >
          {render_slot(@inner_block)}
        </div>
      </div>
    </div>
    """
  end

  # A finished review is the one done run that waits on nothing but the merge, so it reads as done.
  defp chip_style(task, run) do
    if ready_to_merge?(task, run),
      do: %{text_class: "text-emerald-600 dark:text-emerald-400", icon: "pi-check-circle"},
      else: run_state_style(run, task)
  end
end
