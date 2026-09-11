defmodule RailWeb.Components.CompactWaitingStrip do
  @moduledoc false
  use RailWeb, :html

  import RailWeb.CoreComponents, only: [project_badge: 1]

  alias Rail.Domain.Formatters

  attr :block, :any, required: true

  def compact_waiting_strip(assigns) do
    assigns = assign(assigns, :rows, assigns.block.rows)

    ~H"""
    <div
      data-qa="compact-waiting-strip"
      class="mb-3 rounded-lg border border-slate-200 dark:border-slate-700 border-l-4 border-l-amber-600 bg-white dark:bg-slate-900 shadow-xs divide-y divide-slate-200 dark:divide-slate-700"
    >
      <div
        :for={row <- @rows}
        id={"compact-row-#{item_key_to_id(row.item)}"}
        data-qa="compact-waiting-row"
        class="flex items-center justify-between gap-3 px-4 py-3 hover:bg-slate-100 dark:hover:bg-slate-700/40 transition-colors"
      >
        <!-- Left: Status Chip + Project Badge + Title & Error Line -->
        <div class="flex items-center space-x-3 min-w-0 flex-1">
          <span
            data-qa="compact-status-chip"
            class={[
              "px-2 py-0.5 rounded text-[11px] font-bold shrink-0",
              chip_class(row.kind)
            ]}
          >
            {chip_label(row.kind)}
          </span>

          <.project_badge project={row.task.project} />

          <div class="min-w-0 flex-1">
            <.link
              navigate={~p"/tasks/#{row.task.id}"}
              data-qa="compact-row-title"
              class="text-sm font-medium text-slate-900 dark:text-slate-100 hover:underline truncate block"
            >
              {task_title_line(row.task)}
            </.link>

            <p
              :if={has_detail?(row.task)}
              data-qa="compact-detail"
              class="text-xs text-red-600 dark:text-red-400 truncate mt-0.5"
            >
              {task_detail(row.task)}
            </p>
          </div>
        </div>

        <!-- Right: Elapsed + Action Button -->
        <div class="flex items-center space-x-3 shrink-0">
          <span
            id={"elapsed-#{item_key_to_id(row.item)}"}
            phx-hook="Elapsed"
            data-started-at={format_started_at(row.waiting_since)}
            data-qa="elapsed-text"
            class="text-xs text-slate-500 dark:text-slate-400 font-mono"
          >
            {format_elapsed(row.waiting_since)}
          </span>

          <div>
            <.link
              :if={row.kind == :failed}
              navigate={~p"/tasks/#{row.task.id}"}
              id={"action-open-log-#{row.task.id}"}
              data-qa="action-open-log"
              class="px-2.5 py-1 rounded-lg text-xs font-semibold bg-blue-600 dark:bg-blue-500 text-white hover:opacity-90 shadow-xs inline-block"
            >
              Open log
            </.link>

            <button
              :if={row.kind == :ready_to_merge}
              type="button"
              id={"action-merge-#{row.task.id}"}
              data-qa="action-merge"
              phx-click="open_merge"
              phx-value-task_id={row.task.id}
              class="px-2.5 py-1 rounded-lg text-xs font-semibold bg-emerald-700 hover:bg-emerald-600 text-white shadow-xs cursor-pointer"
            >
              Merge
            </button>

            <button
              :if={row.kind == :conflicts}
              type="button"
              id={"action-rebase-#{row.task.id}"}
              data-qa="action-rebase"
              phx-click="open_rebase"
              phx-value-task_id={row.task.id}
              class="px-2.5 py-1 rounded-lg text-xs font-semibold bg-amber-700 hover:bg-amber-600 text-white shadow-xs cursor-pointer"
            >
              Rebase
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp chip_label(:failed), do: "Failed"
  defp chip_label(:ready_to_merge), do: "Ready to merge"
  defp chip_label(:conflicts), do: "Conflicts"
  defp chip_label(_other), do: "Waiting"

  defp chip_class(:failed), do: "bg-red-100 dark:bg-red-950 text-red-900 dark:text-red-200"
  defp chip_class(:ready_to_merge), do: "bg-emerald-100 dark:bg-emerald-950 text-emerald-900 dark:text-emerald-200"
  defp chip_class(:conflicts), do: "bg-orange-100 dark:bg-orange-950 text-orange-900 dark:text-orange-200"
  defp chip_class(_other), do: "bg-amber-100 dark:bg-amber-950 text-amber-900 dark:text-amber-200"

  defp task_title_line(task) do
    task_key = task_key(task)
    "#{task_key} · #{task.issue && task.issue.title}"
  end

  defp task_key(%{issue: %{identifier: identifier}}) when is_binary(identifier) and identifier != "", do: identifier
  defp task_key(%{id: id}) when is_binary(id) and id != "", do: id

  defp format_elapsed(%DateTime{} = dt) do
    secs = max(0, DateTime.diff(DateTime.utc_now(), dt, :second))
    Formatters.format_duration(secs)
  end

  defp format_started_at(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp task_detail(task), do: Formatters.overview_detail_for(task)

  defp has_detail?(task) do
    detail = task_detail(task)
    is_binary(detail) and detail != ""
  end

  defp item_key_to_id(item) do
    key = Rail.Domain.AttentionItem.key(item)
    String.replace(key, ~r/[^a-zA-Z0-9_\-]/, "-")
  end
end
