defmodule Rail.Mcp.Utils.RunToolCommitTest do
  use Rail.DataCase, async: true

  import Rail.Mcp.Utils.RunToolCommit

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Tools.Schemas.OsProcess

  test "an accepted commit says the turn is over and Rail is committing" do
    expect(Pipeline, :end_turn_and_commit, fn %Task{}, %OsProcess{id: "proc_rc"}, "RC-1: the change" ->
      {:ok, :committing}
    end)

    assert {:ok, "Your turn is over. Rail is committing your work" <> _rest} =
             run_tool_commit(%Task{}, %{"message" => "RC-1: the change"}, os_process: %OsProcess{id: "proc_rc"})
  end

  test "a refusal is passed back as it was worded" do
    expect(Pipeline, :end_turn_and_commit, fn %Task{}, %OsProcess{}, nil -> {:refused, "Refused, nothing committed."} end)

    assert {:refused, "Refused, nothing committed."} = run_tool_commit(%Task{}, %{}, os_process: %OsProcess{})
  end
end
