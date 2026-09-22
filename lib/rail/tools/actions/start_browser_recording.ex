defmodule Rail.Tools.Actions.StartBrowserRecording do
  @moduledoc """
  Gets the recording a task is being filmed into, starting one if there is not
  one yet.

  Asking twice gets the same recording rather than a second one filming over the
  first: the registry is keyed by task, so every tool call a demo run makes can
  ask without knowing whether it is the first.

  Nothing here starts a browser. A recording with no browser in front of it is a
  recording of nothing, which is exactly what it should be - the frames only
  arrive once something is driving.
  """

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Tools
  alias Rail.Tools.BrowserRecorder
  alias Rail.Tools.BrowserSupervisor

  @doc """
  Returns `{:ok, pid}` for `task`'s recording, into `<scratch>/demo`.
  """
  def start_browser_recording(%Task{} = task) do
    case Tools.get_browser_recording(task) do
      pid when is_pid(pid) ->
        {:ok, pid}

      nil ->
        child = {BrowserRecorder, [task: task, directory: Path.join(task.scratch_path, "demo")]}

        case DynamicSupervisor.start_child(BrowserSupervisor, child) do
          {:ok, pid} -> {:ok, pid}
          # coveralls-ignore-next-line (two callers that both looked and both found nothing)
          {:error, {:already_started, pid}} -> {:ok, pid}
        end
    end
  end
end
