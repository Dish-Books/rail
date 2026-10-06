defmodule Rail.Mcp.Utils.RunToolSaveSplit do
  @moduledoc """
  Saves the architect's split, every child of it at once, or removes it with no children.
  """

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task

  @doc """
  Saves `arguments["children"]` as `task`'s split, or hands back the changeset that refused it,
  which names each child and field to fix.
  """
  def run_tool_save_split(%Task{} = task, arguments, _opts) do
    case Pipeline.save_split(task, Map.take(arguments, ["children"])) do
      {:ok, %{children: children}} ->
        {:ok,
         "Split saved into #{length(children)} children. Save the whole split again after every change; the human reads the last save."}

      {:ok, nil} ->
        {:ok, "Split removed: approval makes one task."}

      {:error, changeset} ->
        {:error, changeset}
    end
  end
end
