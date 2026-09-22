defmodule Rail.Tools.BrowserRecorderTest do
  use Rail.DataCase, async: true

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Tools
  alias Rail.Tools.BrowserRecorder

  setup do
    unique = System.unique_integer([:positive])
    scratch = Path.join([System.tmp_dir!(), "rail_recorder_test", to_string(unique)])
    task = %Task{id: "tsk_rec_#{unique}", scratch_path: scratch}

    on_exit(fn -> File.rm_rf(scratch) end)

    %{task: task, directory: Path.join(task.scratch_path, "demo")}
  end

  test "writes every frame the browser paints, with when it arrived", %{task: task, directory: directory} do
    {:ok, recorder} = Tools.start_browser_recording(task)

    Phoenix.PubSub.broadcast(Rail.PubSub, "browser:#{task.id}", {:browser_frame, task.id, Base.encode64("first")})
    Phoenix.PubSub.broadcast(Rail.PubSub, "browser:#{task.id}", {:browser_frame, task.id, Base.encode64("second")})

    eventually(fn ->
      assert File.read!(Path.join(directory, "frames/000000.jpg")) == "first"
      assert File.read!(Path.join(directory, "frames/000001.jpg")) == "second"
    end)

    assert ^directory = BrowserRecorder.finish(recorder)

    written =
      directory
      |> Path.join("frames.jsonl")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    assert [%{"file" => "000000.jpg", "at_ms" => 0}, %{"file" => "000001.jpg"}] = written
  end

  # The clock starts at the first frame rather than at the launch, because a
  # video that opens on two seconds of a browser booting is two seconds nobody
  # watches.
  test "the recording has run for nothing until something paints", %{task: task} do
    {:ok, recorder} = Tools.start_browser_recording(task)

    assert BrowserRecorder.elapsed_ms(recorder) == 0

    Phoenix.PubSub.broadcast(Rail.PubSub, "browser:#{task.id}", {:browser_frame, task.id, Base.encode64("painted")})

    eventually(fn -> assert BrowserRecorder.elapsed_ms(recorder) >= 0 end)
    assert BrowserRecorder.finish(recorder)
  end

  test "asking twice films once", %{task: task} do
    assert {:ok, recorder} = Tools.start_browser_recording(task)
    assert {:ok, ^recorder} = Tools.start_browser_recording(task)
    assert ^recorder = Tools.get_browser_recording(task)

    assert BrowserRecorder.finish(recorder)
  end

  # A task demonstrated twice has one demo, and it is the one just recorded.
  test "a second recording replaces the first", %{task: task, directory: directory} do
    File.mkdir_p!(Path.join(directory, "frames"))
    File.write!(Path.join(directory, "frames/000000.jpg"), "from the last recording")

    {:ok, recorder} = Tools.start_browser_recording(task)

    refute File.exists?(Path.join(directory, "frames/000000.jpg"))
    assert BrowserRecorder.finish(recorder)
  end

  # The recorder subscribes to a topic the session also broadcasts other things
  # on, and a message it has no use for is not a reason to stop filming.
  test "a message the recording has no use for changes nothing", %{task: task} do
    {:ok, recorder} = Tools.start_browser_recording(task)

    send(recorder, :something_else)

    assert BrowserRecorder.elapsed_ms(recorder) == 0
    assert BrowserRecorder.finish(recorder)
  end

  test "stopping a task nothing was filming is not an error", %{task: task} do
    assert Tools.get_browser_recording(task) == nil
    assert Tools.stop_browser_recording(task) == nil
  end

  test "stopping says where the frames went", %{task: task, directory: directory} do
    {:ok, _recorder} = Tools.start_browser_recording(task)

    assert Tools.stop_browser_recording(task) == directory
  end
end
