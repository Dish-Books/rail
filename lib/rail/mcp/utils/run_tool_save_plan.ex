defmodule Rail.Mcp.Utils.RunToolSavePlan do
  @moduledoc """
  Saves the architect's plan, from its first draft to its last, with the design option it was written for.
  """

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task

  @doc """
  Saves `arguments["plan"]` as `task`'s plan for `arguments["design"]`, or hands back the
  changeset that refused it.
  """
  def run_tool_save_plan(%Task{} = task, arguments, _opts) do
    case Pipeline.save_plan(task, Map.take(arguments, ["plan", "design"])) do
      {:ok, %{design: %{key: key, title: title}}} ->
        {:ok, "Plan saved for #{title} (#{key}). Save it again after every change; the human reads the last save."}

      {:ok, %{design: nil}} ->
        {:ok,
         "Plan saved, written for no design option yet. Save it again after every change; the human reads the last save."}

      {:error, changeset} ->
        {:error, changeset}
    end
  end
end
