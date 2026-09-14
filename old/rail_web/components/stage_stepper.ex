defmodule RailWeb.Components.StageStepper do
  @moduledoc """
  Horizontal stepper displaying the sequence of pipeline stages for a task.
  Excludes :merged.
  """
  use RailWeb, :html

  import RailWeb.CoreComponents, only: [icon: 1]

  alias Rail.Pipeline.Schemas.Task
  alias RailWeb.Components.RunState

  @canonical_stages [
    :product,
    :design,
    :architect,
    :engineer,
    :review,
    :qa,
    :qa_lead,
    :demo,
    :ready_to_merge
  ]

  attr :task, :any, required: true
  attr :runs, :any, default: []
  attr :run, :any, default: nil
  attr :class, :string, default: nil

  def stage_stepper(assigns) do
    assigns =
      assigns
      |> assign(:stages, @canonical_stages)
      |> assign(:current_stage, assigns.task.stage)

    ~H"""
    <div
      id="stage-stepper"
      data-qa="stage-stepper stage_stepper"
      class={["flex flex-wrap items-center gap-1 sm:gap-2", @class]}
    >
      <%= for {st, idx} <- Enum.with_index(@stages) do %>
        <% is_current = st == @current_stage
        is_done = Task.before?(st, @current_stage)
        icon_name = stage_icon(is_current, is_done, @task, @run)
        chip_style = stage_chip_classes(is_current, is_done, @task, @run)
        label = Task.stage_label(st) %>

        <div
          id={"stage-chip-#{st}"}
          data-qa={"stage-step stage-step-#{st} stage_chip_#{st}"}
          data-stage={st}
          data-current={if is_current, do: "true", else: "false"}
          data-done={if is_done, do: "true", else: "false"}
          class={[
            "inline-flex items-center gap-1.5 px-2.5 py-1 rounded-lg text-xs border transition-colors shrink-0",
            chip_style,
            is_current && "font-bold"
          ]}
        >
          <.icon name={icon_name} class="h-3.5 w-3.5 shrink-0" />
          <span data-qa="stage-label">{label}</span>
        </div>

        <.icon
          :if={idx < length(@stages) - 1}
          name="pi-caret-right"
          class="h-4 w-4 text-slate-300 dark:text-slate-600 shrink-0 hidden sm:inline-block"
        />
      <% end %>
    </div>
    """
  end

  defp stage_icon(true = _is_current, _is_done, task, run), do: RunState.icon(task, run)
  defp stage_icon(_is_current, true = _is_done, _task, _run), do: "pi-check-circle-fill"
  defp stage_icon(_is_current, _is_done, _task, _run), do: "pi-circle"

  defp stage_chip_classes(true = _is_current, _is_done, task, run) do
    case RunState.color(task, run) do
      :primary ->
        "bg-blue-100 dark:bg-blue-900 text-blue-800 dark:text-blue-200 border-blue-600 dark:border-blue-500 font-semibold shadow-xs"

      :amber ->
        "bg-amber-100 dark:bg-amber-950 text-amber-900 dark:text-amber-200 border-amber-500 font-semibold shadow-xs"

      :error ->
        "bg-red-100 dark:bg-red-900 text-red-800 dark:text-red-200 border-red-600 dark:border-red-500 font-semibold shadow-xs"

      _outline ->
        "bg-slate-100 dark:bg-slate-700 text-slate-900 dark:text-slate-100 border-slate-500 dark:border-slate-400 font-semibold shadow-xs"
    end
  end

  defp stage_chip_classes(_is_current, true = _is_done, _task, _run) do
    "bg-emerald-50 dark:bg-emerald-950/40 text-emerald-700 dark:text-emerald-300 border-emerald-500/40"
  end

  defp stage_chip_classes(_is_current, _is_done, _task, _run) do
    "bg-slate-50 dark:bg-slate-800 text-slate-500 dark:text-slate-400 border-slate-300 dark:border-slate-600"
  end
end
