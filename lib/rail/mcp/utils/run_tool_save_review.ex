defmodule Rail.Mcp.Utils.RunToolSaveReview do
  @moduledoc """
  Closes a review pass once every finding in it is saved.
  """

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task

  @doc """
  Records that `task`'s review pass is finished.
  """
  def run_tool_save_review(%Task{} = task, _arguments, _opts) do
    {:ok, _saved_at} = Pipeline.save_review(task)
    {:ok, "Review saved. The pass is finished."}
  end
end
