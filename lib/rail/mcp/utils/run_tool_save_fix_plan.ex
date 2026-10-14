defmodule Rail.Mcp.Utils.RunToolSaveFixPlan do
  @moduledoc """
  Saves the Review lead's plan for the fix round a Send started, in place of the last.
  """

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task

  @doc """
  Saves `arguments["plan"]` as `task`'s fix plan, or hands back the changeset that refused it, which names what to
  fix. Refused outright when no fix plan is due.
  """
  def run_tool_save_fix_plan(%Task{} = task, arguments, _opts) do
    case Pipeline.save_fix_plan(
           task,
           Map.take(arguments, ["plan", "record_demo", "retake_screens", "title", "description", "design_changed"])
         ) do
      {:ok, fix_plan} ->
        {:ok,
         "Fix plan saved as version #{fix_plan.version} of fix round #{fix_plan.round}. Change nothing and end your turn: the human approves it in Rail."}

      {:error, :no_fix_plan} ->
        {:refused,
         "Nothing saved: no fix plan is due. A plan is due only after a Send in the Review tray and before its plan is approved."}

      {:error, changeset} ->
        {:error, changeset}
    end
  end
end
