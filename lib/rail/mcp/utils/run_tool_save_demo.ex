defmodule Rail.Mcp.Utils.RunToolSaveDemo do
  @moduledoc """
  Saves the write-up of a demo's recording.
  """

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Demo
  alias Rail.Pipeline.Schemas.Task

  @fields ["title", "summary", "not_shown"]

  @doc """
  Saves the write-up in `arguments` on `task`, or hands back the changeset that
  refused it.
  """
  def run_tool_save_demo(%Task{} = task, arguments, _opts) do
    with {:ok, %Demo{title: title}} <- Pipeline.save_demo(task, Map.take(arguments, @fields)) do
      {:ok, "Write-up saved: #{title}."}
    end
  end
end
