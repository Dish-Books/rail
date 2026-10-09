defmodule Rail.Mcp.Utils.RunToolSaveReview do
  @moduledoc """
  Closes a Review round once every finding in it is saved.
  """

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task

  @doc """
  Records that the round running on `task` is finished, and says which round it was.
  """
  def run_tool_save_review(%Task{} = task, _arguments, _opts) do
    {:ok, %{round: round}} = Pipeline.save_review(task)
    {:ok, "Round #{round} saved. The round is finished; end the turn with what it found."}
  end
end
