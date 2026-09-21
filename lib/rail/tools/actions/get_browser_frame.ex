defmodule Rail.Tools.Actions.GetBrowserFrame do
  @moduledoc """
  The last thing this task's browser painted, for a panel that has just opened.

  Frames are broadcast as they happen, so a watcher who was already there has
  seen them. One who arrives part way through a pass has missed all of them, and
  a browser sitting on a form nobody is touching will not paint another until
  something moves - so the newest frame is asked for once, on the way in, and
  everything after that arrives on its own.
  """

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Tools
  alias Rail.Tools.BrowserSession

  @doc """
  Returns the newest frame from `task`'s browser as base64 JPEG, or `nil` when
  there is no browser or it has not painted yet.
  """
  def get_browser_frame(%Task{} = task) do
    case Tools.get_browser_session(task) do
      pid when is_pid(pid) -> BrowserSession.last_frame(pid)
      nil -> nil
    end
  end
end
