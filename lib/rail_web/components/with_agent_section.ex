defmodule RailWeb.Components.WithAgentSection do
  @moduledoc false
  use RailWeb, :html

  import RailWeb.CoreComponents, only: [project_badge: 1]

  alias Rail.Runs.Schemas.Run
  alias RailWeb.Components.RunState

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
          id={"with-agent-card-#{row.run.id}"}
          data-qa="with-agent-card"
          class="rounded-lg border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-900 p-3.5 hover:bg-slate-100 dark:hover:bg-slate-700/30 transition-colors shadow-xs"
        >
          <div class="flex items-center justify-between gap-3">
            <div class="min-w-0 flex-1">
              <div class="flex items-center space-x-2 mb-1">
                <.project_badge project={row.run.task.project} />

                <.link
                  navigate={~p"/tasks/#{row.run.task_id}"}
                  id={"with-agent-title-#{row.run.id}"}
                  data-qa="with-agent-title"
                  class="text-sm font-semibold text-slate-900 dark:text-slate-100 hover:underline truncate"
                >
                  {row.run.task.issue && row.run.task.issue.title}
                </.link>
              </div>

              <!-- Subtitle: State Pill + taskKey · roleName -->
              <div class="flex items-center space-x-2 text-xs text-slate-500 dark:text-slate-400">
                <span
                  data-qa="with-agent-state-pill"
                  class={[
                    "px-1.5 py-0.5 rounded text-[10px] font-bold shrink-0",
                    state_pill_class(row.run)
                  ]}
                >
                  {state_pill_label(row.run)}
                </span>

                <span data-qa="with-agent-role-line" class="truncate">
                  {role_line(row.run)}
                </span>
              </div>
            </div>

            <!-- Trailing: Elapsed since updated_at -->
            <span
              id={"elapsed-with-agent-#{row.run.id}"}
              phx-hook="Elapsed"
              data-started-at={format_started_at(row.run.started_at)}
              data-qa="elapsed-text"
              class="text-xs text-slate-500 dark:text-slate-400 font-mono shrink-0"
            >
              {format_elapsed(row.run.started_at)}
            </span>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp state_pill_label(%Run{task: %{is_rebasing: true}}), do: "Rebasing"
  defp state_pill_label(%Run{} = run), do: run |> Run.state() |> RunState.pill_label()

  defp state_pill_class(%Run{task: %{is_rebasing: true}}), do: RunState.pill_class(:running)
  defp state_pill_class(%Run{} = run), do: run |> Run.state() |> RunState.pill_class()

  defp role_line(%Run{task: task} = run), do: "#{task_key(task)} · #{role_name(run)}"

  defp task_key(%{issue: %{identifier: identifier}}) when is_binary(identifier) and identifier != "", do: identifier
  defp task_key(%{id: id}), do: id

  defp role_name(%Run{role: %{name: name}}) when is_binary(name) and name != "", do: name
  defp role_name(%Run{}), do: "Agent"

  defp format_elapsed(%DateTime{} = datetime) do
    DateTime.utc_now() |> DateTime.diff(datetime, :second) |> max(0) |> format_duration()
  end

  defp format_elapsed(_never), do: ""

  defp format_started_at(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp format_started_at(_never), do: nil
end
