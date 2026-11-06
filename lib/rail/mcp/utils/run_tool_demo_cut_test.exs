defmodule Rail.Mcp.Utils.RunToolDemoCutTest do
  use Rail.DataCase, async: true

  import Rail.Mcp.Utils.RunToolDemoCut
  import Rail.Mcp.Utils.RunToolDemoStart

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Tools

  setup do
    unique = System.unique_integer([:positive])
    scratch = Path.join([System.tmp_dir!(), "rail_cut_test", to_string(unique)])
    task = %Task{id: "tsk_cut_#{unique}", scratch_path: scratch, issue: %Issue{}}

    stub(Tools, :start_browser_session, fn ^task, "demo", _opts -> {:ok, self()} end)

    on_exit(fn ->
      Tools.stop_browser_recording(task)
      File.rm_rf(scratch)
    end)

    %{task: task, cuts: Path.join([scratch, "demo", "cuts.jsonl"])}
  end

  test "a cut before the camera is on is refused and writes nothing", %{task: task, cuts: cuts} do
    assert {:refused, said} = run_tool_demo_cut(task, %{}, [])
    assert said =~ "Call demo_start first"

    refute File.exists?(cuts)
  end

  test "a cut is written at the recorder's clock", %{task: task, cuts: cuts} do
    {:ok, _rolling} = run_tool_demo_start(task, %{"browser" => "demo"}, stage: :demo)

    # The clock starts at the first frame, and nothing has painted here.
    assert {:ok, "Cut at 0:00. What the page does from here to your next caption is left out of the video."} =
             run_tool_demo_cut(task, %{}, [])

    {:ok, _again} = run_tool_demo_cut(task, nil, [])

    assert [%{"at_ms" => 0}, %{"at_ms" => 0}] =
             cuts |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
  end
end
