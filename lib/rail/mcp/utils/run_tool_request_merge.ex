defmodule Rail.Mcp.Utils.RunToolRequestMerge do
  @moduledoc """
  Asks Rail to merge the default branch in, ending the turn it is called in.
  """

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task

  @doc """
  Merges the default branch into `task`'s branch, or says why not while the
  turn is still going.
  """
  def run_tool_request_merge(%Task{} = task, _arguments, opts) do
    with {:ok, :merging} <- Pipeline.end_turn_and_merge(task, opts[:os_process]) do
      {:ok,
       "Your turn is over. Rail is merging the default branch in; if it stops on conflicts, they come back to " <>
         "you as a new turn."}
    end
  end
end
