defmodule Rail.Mcp.Utils.RunToolCommit do
  @moduledoc """
  Hands the engineer's or the Review lead's finished work to Rail, ending the turn it is called in.
  """

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task

  @doc """
  Commits `task`'s worktree as `arguments` describe, or says what to settle first while the turn goes on.
  """
  def run_tool_commit(%Task{} = task, arguments, opts) do
    with {:ok, :committing} <- Pipeline.end_turn_and_commit(task, opts[:os_process], arguments) do
      {:ok, "Your turn is over. Rail is committing your work and sending it on; there is nothing more to do."}
    end
  end
end
