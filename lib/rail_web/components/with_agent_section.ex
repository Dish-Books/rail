defmodule RailWeb.Components.WithAgentSection do
  @moduledoc false
  use RailWeb, :html

  alias Rail.Pipeline.Schemas.Run

  attr :runs, :list, required: true

  def with_agent_section(assigns) do
    ~H"""
    <div :if={@runs != []} id="with-agent-section" data-qa="with-agent-section" class="mt-6">
      <h2
        id="with-agent-header"
        data-qa="with-agent-header"
        class="text-xs font-bold uppercase tracking-wider text-slate-500 dark:text-slate-400 mb-2"
      >
        WITH AN AGENT · {length(@runs)} · RECENTLY UPDATED
      </h2>

      <div class="space-y-2">
        <div
          :for={run <- @runs}
          id={"with-agent-card-#{run.id}"}
          data-qa="with-agent-card"
          class="rounded-lg border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-900 p-3.5 hover:bg-slate-100 dark:hover:bg-slate-700/30 transition-colors shadow-xs"
        >
          <div class="flex items-center justify-between gap-3">
            <div class="min-w-0 flex-1">
              <div class="flex items-center space-x-2 mb-1">
                <.project_badge project={run.task.project} />

                <.link
                  navigate={~p"/tasks/#{run.task_id}"}
                  id={"with-agent-title-#{run.id}"}
                  data-qa="with-agent-title"
                  class="text-sm font-semibold text-slate-900 dark:text-slate-100 hover:underline truncate"
                >
                  {run.task.issue.title}
                </.link>
              </div>

              <!-- Subtitle: State Pill + taskKey · roleName -->
              <div class="flex items-center space-x-2 text-xs text-slate-500 dark:text-slate-400">
                <span
                  data-qa="with-agent-state-pill"
                  class={[
                    "px-1.5 py-0.5 rounded text-[10px] font-bold shrink-0",
                    run_state_style(run).chip_class
                  ]}
                >
                  {run_state_style(run).pill_label}
                </span>

                <span data-qa="with-agent-role-line" class="truncate">
                  {role_line(run)}
                </span>
              </div>
            </div>

            <!-- Trailing: Elapsed since updated_at -->
            <span
              id={"elapsed-with-agent-#{run.id}"}
              phx-hook="Elapsed"
              data-started-at={DateTime.to_iso8601(run.started_at)}
              data-qa="elapsed-text"
              class="text-xs text-slate-500 dark:text-slate-400 font-mono shrink-0"
            >
              {format_elapsed(run.started_at)}
            </span>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp role_line(%Run{task: task, role: role}), do: "#{task.issue.identifier} · #{role.name}"

  defp format_elapsed(%DateTime{} = datetime) do
    DateTime.utc_now() |> DateTime.diff(datetime, :second) |> max(0) |> format_duration()
  end
end
