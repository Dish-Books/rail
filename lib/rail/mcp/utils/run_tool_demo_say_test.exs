defmodule Rail.Mcp.Utils.RunToolDemoSayTest do
  use Rail.DataCase, async: true

  import Rail.Mcp.Utils.RunToolDemoSay
  import Rail.Mcp.Utils.RunToolDemoStart

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Tools

  setup do
    unique = System.unique_integer([:positive])
    scratch = Path.join([System.tmp_dir!(), "rail_say_test", to_string(unique)])
    task = %Task{id: "tsk_say_#{unique}", scratch_path: scratch}

    on_exit(fn ->
      Tools.stop_browser_recording(task)
      File.rm_rf(scratch)
    end)

    written = fn ->
      [scratch, "demo", "captions.jsonl"]
      |> Path.join()
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)
    end

    %{task: task, written: written}
  end

  # A caption belongs to a video, so there has to be one being recorded.
  test "a caption before the camera is on belongs to no video", %{task: task} do
    assert {:ok, said} = run_tool_demo_say(task, %{"text" => "Entering a bill"}, [])
    assert said =~ "Call demo_start first"

    refute File.exists?(Path.join([task.scratch_path, "demo", "captions.jsonl"]))
  end

  test "stamps the caption against the recording's clock", %{task: task, written: written} do
    {:ok, _rolling} = run_tool_demo_start(task, %{}, [])

    assert {:ok, said} = run_tool_demo_say(task, %{"text" => "Entering a bill for Sysco"}, [])
    assert said =~ "Said at 0:00"
    assert said =~ "while the caption is up"

    assert [%{"at_ms" => 0, "text" => "Entering a bill for Sysco", "criterion" => nil}] = written.()
  end

  # The criterion is what says the walkthrough covered the ticket rather than
  # wandering around the application, so it is carried through untouched.
  test "a beat that proves a criterion says which", %{task: task, written: written} do
    {:ok, _rolling} = run_tool_demo_start(task, %{}, [])

    {:ok, _said} =
      run_tool_demo_say(
        task,
        %{"text" => "The bill appears on the list", "criterion" => "A saved bill is listed immediately"},
        []
      )

    assert [%{"criterion" => "A saved bill is listed immediately"}] = written.()
  end

  test "every beat is kept, in the order it was said", %{task: task, written: written} do
    {:ok, _rolling} = run_tool_demo_start(task, %{}, [])

    {:ok, _first} = run_tool_demo_say(task, %{"text" => "Opening the bills page"}, [])
    {:ok, _second} = run_tool_demo_say(task, %{"text" => "Entering a bill"}, [])

    assert [%{"text" => "Opening the bills page"}, %{"text" => "Entering a bill"}] = written.()
  end

  test "a call with no words to say records nothing", %{task: task} do
    {:ok, _rolling} = run_tool_demo_start(task, %{}, [])

    assert {:ok, "demo_say needs a `text`. Nothing was recorded."} = run_tool_demo_say(task, %{}, [])

    refute File.exists?(Path.join([task.scratch_path, "demo", "captions.jsonl"]))
  end
end
