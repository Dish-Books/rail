defmodule Rail.Tools.Actions.StopBrowserRecording do
  @moduledoc """
  Stops filming a task and says where the frames are.

  Stopping one that was never started is not an error: the caller is saying there
  should be no recording running, which is already true. What it gets back then
  is `nil` rather than a directory, and a directory nobody recorded into is the
  difference between "no demo" and "an empty one".
  """

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Tools
  alias Rail.Tools.BrowserRecorder

  @doc """
  Stops `task`'s recording and returns the directory it wrote, or nil when there
  was nothing filming.
  """
  def stop_browser_recording(%Task{} = task) do
    case Tools.get_browser_recording(task) do
      pid when is_pid(pid) -> BrowserRecorder.finish(pid)
      nil -> nil
    end
  end
end
