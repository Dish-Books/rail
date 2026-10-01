defmodule Rail.Mcp.Utils.RunToolDemoStartTest do
  use Rail.DataCase, async: true

  import Rail.Mcp.Utils.RunToolDemoStart

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Tools
  alias Rail.Tools.BrowserRecorder

  setup do
    unique = System.unique_integer([:positive])
    scratch = Path.join([System.tmp_dir!(), "rail_start_test", to_string(unique)])
    task = %Task{id: "tsk_start_#{unique}", scratch_path: scratch}

    on_exit(fn ->
      Tools.stop_browser_recording(task)
      File.rm_rf(scratch)
    end)

    %{task: task, frames: Path.join([scratch, "demo", "frames.jsonl"])}
  end

  # A page nobody is touching paints nothing, so without the frame already on
  # screen the clock would wait for the first change and every caption before it
  # would pile up at 0:00.
  test "a take opens on what the browser is already showing", %{task: task, frames: frames} do
    stub(Tools, :get_browser_frame, fn ^task -> Base.encode64("still page") end)

    assert {:ok, rolling} = run_tool_demo_start(task, %{}, [])
    assert rolling =~ "Recording."

    eventually(fn ->
      assert File.read!(Path.join([task.scratch_path, "demo", "frames", "000000.jpg"])) == "still page"

      assert [%{"file" => "000000.jpg", "at_ms" => 0}] =
               frames |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    end)

    assert BrowserRecorder.elapsed_ms(Tools.get_browser_recording(task)) >= 0
  end

  test "a take with no browser yet waits for its first paint", %{task: task, frames: frames} do
    assert {:ok, _rolling} = run_tool_demo_start(task, %{}, [])

    assert BrowserRecorder.elapsed_ms(Tools.get_browser_recording(task)) == 0
    refute File.exists?(frames)
  end
end
