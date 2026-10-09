defmodule Rail.Mcp.Utils.RunToolCommitFixes do
  @moduledoc """
  Hands the Review lead's fix round to Rail, ending the turn it is called in.
  """

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task

  @doc """
  Commits the round `arguments` describes on `task`, or says what to settle first while the turn goes on.
  """
  def run_tool_commit_fixes(%Task{} = task, arguments, opts) do
    with {:ok, :committing} <- Pipeline.end_turn_and_commit_fixes(task, opts[:os_process], arguments) do
      {:ok, "Your turn is over. Rail is committing the fix round and running CI; the next round starts once it passes."}
    end
  end
end
