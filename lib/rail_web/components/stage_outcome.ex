defmodule RailWeb.Components.StageOutcome do
  @moduledoc """
  Renders the outcome or failure details of a role run for the current stage.
  Per spec 05 §7, does not parse or invent verdict badges.
  """
  use RailWeb, :html

  import RailWeb.CoreComponents, only: [markdown: 1]

  attr :task, :any, required: true
  attr :role_run, :any, default: nil
  attr :role_name, :any, default: nil
  attr :class, :string, default: nil

  def stage_outcome(assigns) do
    task = assigns.task
    run = assigns.role_run

    output = if run, do: String.trim(get_field(run, :output) || ""), else: ""
    error = if run, do: String.trim(get_field(run, :error) || ""), else: ""

    is_pruned =
      if run, do: get_field(run, :run_pruned) == true or get_field(run, :is_pruned) == true, else: false

    is_failed = stage_state_failed?(task)
    has_output = output != ""
    has_error = is_failed and error != ""

    visible = run != nil and (has_output or has_error or is_pruned)
    resolved_role_name = resolve_role_name(assigns.role_name, run, task)

    assigns =
      assigns
      |> assign(:visible, visible)
      |> assign(:output, output)
      |> assign(:error, error)
      |> assign(:is_pruned, is_pruned)
      |> assign(:has_output, has_output)
      |> assign(:has_error, has_error)
      |> assign(:resolved_role_name, resolved_role_name)

    ~H"""
    <div :if={@visible} id="stage-outcome" data-qa="stage_outcome" class={["space-y-6", @class]}>
      <!-- Failure Block -->
      <div :if={@has_error} id="stage-failure-section" class="space-y-2">
        <h3
          id="stage-failure-heading"
          data-qa="stage_failure_heading"
          class="text-base font-bold text-[var(--color-error)]"
        >
          {@resolved_role_name} Failure
        </h3>
        <div
          id="stage-failure-box"
          data-qa="stage_failure_box"
          class="w-full p-4 rounded-lg bg-[var(--color-error-container)] text-[var(--color-on-error-container)] font-mono text-xs whitespace-pre-wrap select-text break-words"
        >
          {@error}
        </div>
      </div>

      <!-- Outcome Block -->
      <div :if={@has_output or @is_pruned} id="stage-outcome-section" class="space-y-2">
        <h3
          id="stage-outcome-heading"
          data-qa="stage_outcome_heading"
          class="text-base font-bold text-[var(--color-on-surface)]"
        >
          {@resolved_role_name} Outcome
        </h3>
        <div id="stage-outcome-card" data-qa="stage_outcome_card" class="m3-card p-4 select-text">
          <p :if={@is_pruned} class="text-sm text-[var(--color-outline)]">
            This transcript aged out and was swept.
          </p>
          <.markdown :if={not @is_pruned} content={@output} />
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Formats a role or stage ID into a human-readable title.
  """
  def format_role_id(nil), do: "Stage"
  def format_role_id(id) when is_atom(id), do: id |> to_string() |> format_role_id()

  def format_role_id(id) when is_binary(id) do
    case id do
      "design" -> "Designer"
      "designer" -> "Designer"
      "review" -> "Reviewer"
      "reviewer" -> "Reviewer"
      "qa_lead" -> "QA Lead"
      other -> other |> String.split("_") |> Enum.map_join(" ", &String.capitalize/1)
    end
  end

  def format_role_id(other), do: other |> to_string() |> format_role_id()

  defp resolve_role_name(name, _run, _task) when is_binary(name) and name != "", do: name

  defp resolve_role_name(_name, run, task) do
    role_id =
      cond do
        run != nil and get_field(run, :role_id) != nil -> get_field(run, :role_id)
        task != nil and get_field(task, :current_role_id) != nil -> get_field(task, :current_role_id)
        task != nil and get_field(task, :stage) != nil -> get_field(task, :stage)
        true -> "Stage"
      end

    format_role_id(role_id)
  end

  defp stage_state_failed?(task) do
    get_field(task, :stage_state) in [:failed, "failed"]
  end

  defp get_field(%_struct_mod{} = struct, field), do: Map.get(struct, field)

  defp get_field(map, field) when is_map(map) do
    Map.get(map, field) || Map.get(map, to_string(field))
  end

  defp get_field(_other, _field), do: nil
end
