defmodule Rail.Tools.Actions.GetBrowserRecording do
  @moduledoc """
  The recording a task is being filmed into, if it is being filmed at all.

  Asking rather than starting, for the same reason `get_browser_session/1` is
  separate from starting one: a panel drawing itself should not begin a recording
  by looking at the page.
  """

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Tools.RecorderRegistry

  @doc """
  Returns the recorder process for `task`, or nil.
  """
  def get_browser_recording(%Task{id: task_id}) do
    case Registry.lookup(RecorderRegistry, task_id) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  end
end
