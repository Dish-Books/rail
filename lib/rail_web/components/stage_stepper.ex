defmodule RailWeb.Components.StageStepper do
  @moduledoc """
  Horizontal stepper displaying the sequence of pipeline stages for a task.
  Excludes :merged, and excludes :design when uses_design? is false.
  """
  use RailWeb, :html

  import RailWeb.CoreComponents, only: [icon: 1]

  alias Rail.Domain.Enums.TaskStage
  alias Rail.Domain.Formatters

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
  attr :role_runs, :any, default: []
  attr :class, :string, default: nil

  def stage_stepper(assigns) do
    task = assigns.task
    role_runs = assigns.role_runs
    stages = stages_for_task(task, role_runs)
    current_stage = stage_atom(task)

    assigns =
      assigns
      |> assign(:stages, stages)
      |> assign(:current_stage, current_stage)

    ~H"""
    <div
      id="stage-stepper"
      data-qa="stage_stepper"
      class={["flex flex-wrap items-center gap-1 sm:gap-2", @class]}
    >
      <%= for {st, idx} <- Enum.with_index(@stages) do %>
        <% is_current = st == @current_stage
        is_done = TaskStage.before?(st, @current_stage)
        icon_name = stage_icon(st, is_current, is_done, @task)
        chip_style = stage_chip_classes(is_current, is_done, @task)
        label = TaskStage.label(st) %>

        <div
          id={"stage-chip-#{st}"}
          data-qa={"stage_chip_#{st}"}
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
          <span>{label}</span>
        </div>

        <.icon
          :if={idx < length(@stages) - 1}
          name="chevron_right"
          class="h-4 w-4 text-[var(--color-outline-variant)] shrink-0 hidden sm:inline-block"
        />
      <% end %>
    </div>
    """
  end

  defp stages_for_task(task, role_runs) do
    uses_design = Formatters.uses_design?(task, role_runs: role_runs)

    if uses_design do
      @canonical_stages
    else
      List.delete(@canonical_stages, :design)
    end
  end

  defp stage_icon(_stage, true = _is_current, _is_done, task) do
    Formatters.stage_state_icon(task)
  end

  defp stage_icon(_stage, _is_current, true = _is_done, _task) do
    "check_circle"
  end

  defp stage_icon(_stage, _is_current, _is_done, _task) do
    "radio_button_unchecked"
  end

  defp stage_chip_classes(true = _is_current, _is_done, task) do
    case Formatters.stage_state_color(task) do
      :primary ->
        "bg-[var(--color-primary-container)] text-[var(--color-on-primary-container)] border-[var(--color-primary)] font-semibold shadow-xs"

      :amber ->
        "bg-amber-100 dark:bg-amber-950 text-amber-900 dark:text-amber-200 border-amber-500 font-semibold shadow-xs"

      :error ->
        "bg-[var(--color-error-container)] text-[var(--color-on-error-container)] border-[var(--color-error)] font-semibold shadow-xs"

      _outline ->
        "bg-[var(--color-surface-container-high)] text-[var(--color-on-surface)] border-[var(--color-outline)] font-semibold shadow-xs"
    end
  end

  defp stage_chip_classes(_is_current, true = _is_done, _task) do
    "bg-emerald-50 dark:bg-emerald-950/40 text-emerald-700 dark:text-emerald-300 border-emerald-500/40"
  end

  defp stage_chip_classes(_is_current, _is_done, _task) do
    "bg-[var(--color-surface-container-low)] text-[var(--color-outline)] border-[var(--color-outline-variant)]"
  end

  defp stage_atom(%{stage: stage}) when is_atom(stage), do: stage

  defp stage_atom(%{stage: stage}) when is_binary(stage) do
    String.to_existing_atom(stage)
  rescue
    _error -> :product
  end

  defp stage_atom(_other), do: :product
end
