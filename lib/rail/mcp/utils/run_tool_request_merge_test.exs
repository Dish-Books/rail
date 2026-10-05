defmodule Rail.Mcp.Utils.RunToolRequestMergeTest do
  use Rail.DataCase, async: true

  import Rail.Mcp.Utils.RunToolRequestMerge

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Tools.Schemas.OsProcess

  test "an accepted request says the turn is over and conflicts come back as a turn" do
    expect(Pipeline, :end_turn_and_merge, fn %Task{}, %OsProcess{id: "proc_rm"} -> {:ok, :merging} end)

    assert {:ok, text} = run_tool_request_merge(%Task{}, %{}, os_process: %OsProcess{id: "proc_rm"})
    assert text =~ "Your turn is over. Rail is merging the default branch in"
    assert text =~ "they come back to you as a new turn"
  end

  test "a refusal or a failure is passed back as it came" do
    expect(Pipeline, :end_turn_and_merge, fn %Task{}, %OsProcess{} -> {:refused, "Refused, nothing merged."} end)
    assert {:refused, "Refused, nothing merged."} = run_tool_request_merge(%Task{}, %{}, os_process: %OsProcess{})

    expect(Pipeline, :end_turn_and_merge, fn %Task{}, %OsProcess{} -> {:error, "no network"} end)
    assert {:error, "no network"} = run_tool_request_merge(%Task{}, %{}, os_process: %OsProcess{})
  end
end
