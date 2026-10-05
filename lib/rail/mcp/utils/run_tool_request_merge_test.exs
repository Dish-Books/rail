defmodule Rail.Mcp.Utils.RunToolRequestMergeTest do
  use Rail.DataCase, async: true

  import Rail.Mcp.Utils.RunToolRequestMerge

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task

  test "an accepted request says the turn is over and conflicts come back as a turn" do
    expect(Pipeline, :end_turn_and_merge, fn %Task{} -> {:ok, :merging} end)

    assert {:ok, text} = run_tool_request_merge(%Task{}, %{}, [])
    assert text =~ "Your turn is over. Rail is merging the default branch in"
    assert text =~ "they come back to you as a new turn"
  end

  test "a refusal or a failure is passed back as it came" do
    expect(Pipeline, :end_turn_and_merge, fn %Task{} -> {:refused, "Refused, nothing merged."} end)
    assert {:refused, "Refused, nothing merged."} = run_tool_request_merge(%Task{}, %{}, [])

    expect(Pipeline, :end_turn_and_merge, fn %Task{} -> {:error, "no network"} end)
    assert {:error, "no network"} = run_tool_request_merge(%Task{}, %{}, [])
  end
end
