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
  attr :title, :string, default: nil

  slot :meta
  slot :actions
  slot :alerts
  slot :inner_block
  slot :sidebar

  def task_layout(assigns) do
    ~H"""
    <div class="-m-6 h-[calc(100%+3rem)] flex flex-col min-h-0">
      <div
        id="task-header"
        data-qa="task-header"
        class="px-6 py-5 space-y-3 border-b border-slate-200 dark:border-slate-700"
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
            :if={@run != nil}
            id="task-status-chip"
            data-qa="task_status_chip"
            class={["font-semibold", run_state_style(@run).text_class]}
          >
            {stage_label(@task, @run)}
          </span>

          <span data-qa="task_issue_identifier" class="font-mono">
            {@task.issue.identifier}
          </span>
          <span data-qa="task_branch_name" class="font-mono">{@task.worktree_name}</span>

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
        <div id="task-main-column" class="flex-1 min-w-0 overflow-y-auto px-6 py-8">
          {render_slot(@inner_block)}
        </div>

        <aside
          id="task-conversation-column"
          class="w-full lg:w-[440px] shrink-0 flex flex-col min-h-0 border-t lg:border-t-0 lg:border-l border-slate-200 dark:border-slate-700"
        >
          {render_slot(@sidebar)}
        </aside>
      </div>
    </div>
    """
  end
end
