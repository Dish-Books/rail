defmodule Rail.Mcp.Utils.RunToolCommitTest do
  use Rail.DataCase, async: true

  import Rail.Mcp.Utils.RunToolCommit

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task

  test "an accepted commit says the turn is over and Rail is committing" do
    expect(Pipeline, :end_turn_and_commit, fn %Task{}, "RC-1: the change" -> {:ok, :committing} end)

    assert {:ok, "Your turn is over. Rail is committing your work" <> _rest} =
             run_tool_commit(%Task{}, %{"message" => "RC-1: the change"}, [])
  end

  test "a refusal is passed back as it was worded" do
    expect(Pipeline, :end_turn_and_commit, fn %Task{}, nil -> {:refused, "Refused, nothing committed."} end)

    assert {:refused, "Refused, nothing committed."} = run_tool_commit(%Task{}, %{}, [])
  end
end
