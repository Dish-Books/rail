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
    expect(Tools, :start_browser_session, fn ^task, "demo", [existing: true, stage: :demo] -> {:ok, self()} end)
    stub(Tools, :get_browser_frame, fn ^task, "demo" -> Base.encode64("still page") end)

    assert {:ok, rolling} = run_tool_demo_start(task, %{"browser" => "demo"}, stage: :demo)
    assert rolling =~ "Recording."

    eventually(fn ->
      assert File.read!(Path.join([task.scratch_path, "demo", "frames", "000000.jpg"])) == "still page"

      assert [%{"file" => "000000.jpg", "at_ms" => 0}] =
               frames |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    end)

    assert BrowserRecorder.elapsed_ms(Tools.get_browser_recording(task)) >= 0
  end

  # A lead that drives a second browser films that one when it names it.
  test "a take films the browser it names", %{task: task} do
    expect(Tools, :start_browser_session, fn ^task, "signup", [existing: true, stage: :demo] -> {:ok, self()} end)
    stub(Tools, :get_browser_frame, fn ^task, "signup" -> Base.encode64("sign-up page") end)

    assert {:ok, _rolling} = run_tool_demo_start(task, %{"browser" => "signup"}, stage: :demo)

    eventually(fn ->
      assert File.read!(Path.join([task.scratch_path, "demo", "frames", "000000.jpg"])) == "sign-up page"
    end)
  end

  # Each agent that drives the app has a browser of its own, named for its part.
  test "a take that names no browser films the recorder's own", %{task: task} do
    expect(Tools, :start_browser_session, fn ^task, "demo", [existing: false, stage: :demo] -> {:ok, self()} end)
    stub(Tools, :get_browser_frame, fn ^task, "demo" -> Base.encode64("still page") end)

    assert {:ok, "Recording." <> _rest} = run_tool_demo_start(task, %{}, stage: :demo)
  end

  test "another stage's run that names no browser films the one named for its stage", %{task: task} do
    expect(Tools, :start_browser_session, fn ^task, "demo", [existing: false, stage: :demo] -> {:ok, self()} end)

    assert {:ok, "Recording." <> _rest} = run_tool_demo_start(task, %{}, stage: :demo)
  end

  test "a browser name Rail will not key a browser by is refused", %{task: task} do
    assert {:refused, "`browser` is a name" <> _rest} =
             run_tool_demo_start(task, %{"browser" => "a/b"}, stage: :demo)

    assert {:refused, _not_text} = run_tool_demo_start(task, %{"browser" => 7}, stage: :demo)
    refute Tools.get_browser_recording(task)
  end

  test "a take of a browser that has painted nothing yet waits for its first paint", %{task: task, frames: frames} do
    expect(Tools, :start_browser_session, fn ^task, "demo", _opts -> {:ok, self()} end)

    assert {:ok, _rolling} = run_tool_demo_start(task, %{"browser" => "demo"}, stage: :demo)

    assert BrowserRecorder.elapsed_ms(Tools.get_browser_recording(task)) == 0
    refute File.exists?(frames)
  end
end
