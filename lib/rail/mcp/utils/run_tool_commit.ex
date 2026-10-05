defmodule Rail.Mcp.Utils.RunToolCommit do
  @moduledoc """
  Hands the engineer's finished work to Rail, ending the turn it is called in.
  """

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task

  @doc """
  Commits `task`'s worktree under `arguments["message"]`, or says why not while
  the turn is still going.
  """
  def run_tool_commit(%Task{} = task, arguments, _opts) do
    with {:ok, :committing} <- Pipeline.end_turn_and_commit(task, arguments["message"]) do
      {:ok, "Your turn is over. Rail is committing your work and sending it on; there is nothing more to do."}
    end
  end
end
