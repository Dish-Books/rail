defmodule Rail.Mcp.Utils.RunToolCommitTest do
  use Rail.DataCase, async: true

  import Rail.Mcp.Utils.RunToolCommit

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Tools.Schemas.OsProcess

  # The arguments go through whole, since at Review they also carry what the round fixed.
  test "an accepted commit says the turn is over and Rail is committing" do
    arguments = %{"message" => "RC-1: the change", "findings" => [%{"key" => "nil-crash"}]}

    expect(Pipeline, :end_turn_and_commit, fn %Task{}, %OsProcess{id: "proc_rc"}, ^arguments ->
      {:ok, :committing}
    end)

    assert {:ok, "Your turn is over. Rail is committing your work" <> _rest} =
             run_tool_commit(%Task{}, arguments, os_process: %OsProcess{id: "proc_rc"})
  end

  test "a refusal is passed back as it was worded" do
    expect(Pipeline, :end_turn_and_commit, fn %Task{}, %OsProcess{}, %{} -> {:refused, "Refused, nothing committed."} end)

    assert {:refused, "Refused, nothing committed."} = run_tool_commit(%Task{}, %{}, os_process: %OsProcess{})
  end
end
