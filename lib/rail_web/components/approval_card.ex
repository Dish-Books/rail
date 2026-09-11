defmodule RailWeb.Components.ApprovalCard do
  @moduledoc false
  use RailWeb, :html

  import RailWeb.CoreComponents, only: [project_badge: 1]

  alias Rail.Domain.Formatters

  attr :row, :any, required: true

  def approval_card(assigns) do
    row = assigns.row
    task = row.task
    task_key = task_key(task)
    role_name = role_name(task)
    header_label = if task_key, do: "#{task_key} · #{role_name}", else: role_name
    stage_chip_label = Formatters.stage_label(task)
    detail = Formatters.overview_detail_for(task)
    {primary_label, primary_tab} = primary_action(task)
    elapsed_text = format_elapsed(row.waiting_since)
    started_at = format_started_at(row.waiting_since)
    card_id = item_key_to_id(row.item)

    assigns =
      assigns
      |> assign(:task, task)
      |> assign(:task_key, task_key)
      |> assign(:role_name, role_name)
      |> assign(:header_label, header_label)
      |> assign(:stage_chip_label, stage_chip_label)
      |> assign(:detail, detail)
      |> assign(:primary_label, primary_label)
      |> assign(:primary_tab, primary_tab)
      |> assign(:elapsed_text, elapsed_text)
      |> assign(:started_at, started_at)
      |> assign(:card_id, card_id)

    ~H"""
    <div
      id={"approval-card-#{@card_id}"}
      data-qa="overview-card approval-card"
      class="mb-3 rounded-lg border border-slate-200 dark:border-slate-700 border-l-4 border-l-amber-600 bg-white dark:bg-slate-900 p-4 shadow-xs"
    >
      <!-- Header Row -->
      <div class="flex items-center justify-between gap-2 mb-2">
        <div class="flex items-center space-x-2 truncate">
          <span
            data-qa="stage-approval-chip"
            class="px-2 py-0.5 rounded text-[11px] font-bold bg-amber-100 dark:bg-amber-950 text-amber-900 dark:text-amber-200 shrink-0"
          >
            {@stage_chip_label}
          </span>

          <.project_badge project={@task.project} />

          <.link
            navigate={~p"/tasks/#{@task.id}"}
            id={"approval-task-link-#{@card_id}"}
            data-qa="approval-task-link"
            class="text-xs font-semibold text-slate-600 dark:text-slate-300 hover:underline truncate"
          >
            {@header_label}
          </.link>
        </div>

        <span
          id={"elapsed-#{@card_id}"}
          phx-hook="Elapsed"
          data-started-at={@started_at}
          data-qa="elapsed-text"
          class="text-xs text-slate-500 dark:text-slate-400 font-mono shrink-0"
        >
          {@elapsed_text}
        </span>
      </div>

      <!-- Task Title -->
      <h3 class="text-base font-semibold text-slate-900 dark:text-slate-100 mb-1">
        <.link
          navigate={~p"/tasks/#{@task.id}"}
          id={"approval-title-link-#{@card_id}"}
          data-qa="approval-title"
          class="hover:underline"
        >
          {@task.issue && @task.issue.title}
        </.link>
      </h3>

      <!-- Optional Detail Line -->
      <p
        :if={is_binary(@detail) and @detail != ""}
        id={"approval-detail-#{@card_id}"}
        data-qa="approval-detail"
        class="text-xs text-slate-500 dark:text-slate-400 truncate mb-3"
      >
        {@detail}
      </p>

      <!-- Action Buttons -->
      <div class="flex items-center space-x-2.5 mt-3 pt-2 border-t border-slate-200 dark:border-slate-700">
        <.link
          navigate={~p"/tasks/#{@task.id}?tab=#{@primary_tab}"}
          id={"approval-primary-action-#{@card_id}"}
          data-qa="approval-primary-action"
          class="inline-flex items-center px-3 py-1.5 rounded-lg bg-blue-600 dark:bg-blue-500 text-white hover:opacity-90 text-xs font-semibold shadow-xs"
        >
          {@primary_label}
        </.link>

        <button
          type="button"
          id={"send-back-button-#{@card_id}"}
          data-qa="send-back-button"
          phx-click="open_send_back"
          phx-value-task_id={@task.id}
          class="inline-flex items-center px-3 py-1.5 rounded-lg border border-slate-500 dark:border-slate-400 text-slate-900 dark:text-slate-100 hover:bg-slate-100 dark:hover:bg-slate-700 text-xs font-semibold cursor-pointer"
        >
          Send back with comments
        </button>
      </div>
    </div>
    """
  end

  defp primary_action(%{stage: :architect}), do: {"Open plan", "plan"}
  defp primary_action(%{stage: :product}), do: {"Open ticket", "overview"}
  defp primary_action(_task), do: {"Open diff", "diff"}

  defp task_key(%{issue: %{identifier: identifier}}) when is_binary(identifier) and identifier != "", do: identifier
  defp task_key(%{id: id}) when is_binary(id) and id != "", do: id

  defp role_name(%{stage: stage}) when stage != nil, do: format_role_id(to_string(stage))
  defp role_name(_task), do: "Agent"

  defp format_role_id(other) when is_binary(other) do
    other
    |> String.split("_")
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp format_elapsed(%DateTime{} = dt) do
    secs = max(0, DateTime.diff(DateTime.utc_now(), dt, :second))
    Formatters.format_duration(secs)
  end

  defp format_started_at(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp item_key_to_id(item) do
    key = Rail.Domain.AttentionItem.key(item)
    String.replace(key, ~r/[^a-zA-Z0-9_\-]/, "-")
  end
end
