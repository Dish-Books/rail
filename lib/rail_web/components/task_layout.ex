defmodule RailWeb.Components.TaskLayout do
  @moduledoc """
  The frame every task page sits in: a header across the top, the stage's work
  below it, and the conversation in a sidebar on the right.

  The stage decides the title, the meta line and the actions; the page decides
  the sidebar. Either can be the one rendering the frame, so it takes all of
  them as slots.
  """
  use RailWeb, :html

  attr :task, :any, required: true
  attr :run, :any, default: nil
  # The status reads the task's stage, whichever tab is open; nil when that stage has no run yet.
  attr :stage_run, :any, required: true
  # What that run waits on: its place in the line for a sandbox, or `Rail.Tools.get_usage_wait/1`.
  attr :line, :map, default: nil
  attr :title, :string, default: nil
  attr :flush, :boolean, default: false

  slot :meta
  slot :tabs
  slot :actions
  slot :alerts
  slot :inner_block
  slot :sidebar

  def task_layout(assigns) do
    assigns =
      assigns
      |> assign(:sandbox_line, if(is_map_key(assigns.line || %{}, :position), do: assigns.line))
      |> assign(:starts_at, if(is_map_key(assigns.line || %{}, :accounts), do: assigns.line.resets_at))

    ~H"""
    <div class="-m-6 h-[calc(100%+3rem)] flex flex-col min-h-0">
      <div
        id="task-header"
        data-qa="task-header"
        class={[
          "px-6 pt-5 space-y-3 border-b border-slate-200 dark:border-slate-700",
          @tabs == [] && "pb-5",
          @tabs != [] && "bg-slate-50 dark:bg-slate-800/30"
        ]}
      >
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
            id="task-status-chip"
            data-qa="task_status_chip"
            class={[
              "inline-flex items-center gap-1.5 font-semibold",
              run_state_style(@stage_run).text_class
            ]}
          >
            <.icon :if={@line} name={run_state_style(@stage_run).icon} class="h-4 w-4" />
            {stage_label(@task, @stage_run)}
            <span :if={@starts_at} id="task-usage-starts" data-qa="task_usage_starts">
              · starts <.local_time id="task-usage-starts-at" at={@starts_at} />
            </span>
          </span>

          <span data-qa="task_issue_identifier" class="font-mono">
            {@task.issue.identifier}
          </span>
          <span data-qa="task_branch_name" class="font-mono">{@task.worktree_name}</span>
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

        {render_slot(@tabs)}
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

        <!-- A pane read on its own leaves no column behind: it has the width. -->
        <aside
          :if={@sidebar != []}
          id="task-conversation-column"
          class="w-full lg:w-[440px] flex-1 lg:flex-none flex flex-col min-h-0 border-t lg:border-t-0 lg:border-l border-slate-200 dark:border-slate-700"
        >
          {render_slot(@sidebar)}
        </aside>
      </div>
    </div>
    """
  end
end
