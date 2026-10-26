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
           Map.take(arguments, ["plan", "record_demo", "title", "description", "design_changed"])
         ) do
      {:ok, fix_plan} ->
        {:ok,
         "Fix plan saved as version #{fix_plan.version} of fix round #{fix_plan.round}. Change nothing and end your turn: the human approves it in Rail."}

      {:error, :no_fix_plan} ->
        {:refused,
         "Nothing saved: no fix plan is due. A plan is due once the round's review is saved, until the task merges."}

      {:error, :nothing_to_fix} ->
        {:refused,
         "Nothing saved: nothing is ruled Fix, no comment asks for a change and the ticket and design stay as they are, so there is no round to plan. End your turn: the human finishes the review."}

      {:error, changeset} ->
        {:error, changeset}
    end
  end
end
