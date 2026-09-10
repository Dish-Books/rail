defmodule RailWeb.Components.WithAgentSection do
  @moduledoc false
  use RailWeb, :html

  import RailWeb.CoreComponents, only: [project_badge: 1]

  alias Rail.Domain.Formatters

  attr :rows, :list, required: true

  def with_agent_section(assigns) do
    ~H"""
    <div :if={@rows != []} id="with-agent-section" data-qa="with-agent-section" class="mt-6">
      <h2
        id="with-agent-header"
        data-qa="with-agent-header"
        class="text-xs font-bold uppercase tracking-wider text-slate-500 dark:text-slate-400 mb-2"
      >
        WITH AN AGENT · {length(@rows)} · RECENTLY UPDATED
      </h2>

      <div class="space-y-2">
        <div
          :for={row <- @rows}
          id={"with-agent-card-#{row.task.id}"}
          data-qa="with-agent-card"
          class="rounded-lg border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-900 p-3.5 hover:bg-slate-100 dark:hover:bg-slate-700/30 transition-colors shadow-xs"
        >
          <div class="flex items-center justify-between gap-3">
            <div class="min-w-0 flex-1">
              <div class="flex items-center space-x-2 mb-1">
                <.project_badge project={row.task.project} />

                <.link
                  navigate={~p"/tasks/#{row.task.id}"}
                  id={"with-agent-title-#{row.task.id}"}
                  data-qa="with-agent-title"
                  class="text-sm font-semibold text-slate-900 dark:text-slate-100 hover:underline truncate"
                >
                  {row.task.title}
                </.link>
              </div>

              <!-- Subtitle: State Pill + taskKey · roleName -->
              <div class="flex items-center space-x-2 text-xs text-slate-500 dark:text-slate-400">
                <span
                  data-qa="with-agent-state-pill"
                  class={[
                    "px-1.5 py-0.5 rounded text-[10px] font-bold shrink-0",
                    state_pill_class(row.task)
                  ]}
                >
                  {state_pill_label(row.task)}
                </span>

                <span data-qa="with-agent-role-line" class="truncate">
                  {task_role_line(row.task)}
                </span>
              </div>
            </div>

            <!-- Trailing: Elapsed since updated_at -->
            <span
              id={"elapsed-with-agent-#{row.task.id}"}
              phx-hook="Elapsed"
              data-started-at={format_started_at(row.task.updated_at)}
              data-qa="elapsed-text"
              class="text-xs text-slate-500 dark:text-slate-400 font-mono shrink-0"
            >
              {format_elapsed(row.task.updated_at)}
            </span>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp state_pill_label(%{is_rebasing: true}), do: "Rebasing"
  defp state_pill_label(%{stage_state: :running}), do: "Running"
  defp state_pill_label(%{stage_state: :queued}), do: "Queued"
  defp state_pill_label(%{stage_state: :blocked}), do: "Blocked"
  defp state_pill_label(%{stage_state: :awaiting_approval}), do: "Awaiting approval"
  defp state_pill_label(%{stage_state: :failed}), do: "Failed"

  defp state_pill_class(%{is_rebasing: true}), do: "bg-blue-100 dark:bg-blue-950 text-blue-900 dark:text-blue-200"
  defp state_pill_class(%{stage_state: :running}), do: "bg-blue-100 dark:bg-blue-950 text-blue-900 dark:text-blue-200"
  defp state_pill_class(%{stage_state: :queued}), do: "bg-slate-100 dark:bg-slate-800 text-slate-800 dark:text-slate-200"

  defp state_pill_class(%{stage_state: s}) when s in [:blocked, :awaiting_approval],
    do: "bg-amber-100 dark:bg-amber-950 text-amber-900 dark:text-amber-200"

  defp state_pill_class(%{stage_state: :failed}), do: "bg-red-100 dark:bg-red-950 text-red-900 dark:text-red-200"

  defp task_role_line(task) do
    task_key = task_key(task)
    role = role_name(task)
    "#{task_key} · #{role}"
  end

  defp task_key(%{issue: %{identifier: identifier}}) when is_binary(identifier) and identifier != "", do: identifier
  defp task_key(%{id: id}) when is_binary(id) and id != "", do: id

  defp role_name(%{role: %{name: name}}) when is_binary(name) and name != "", do: name
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
end
