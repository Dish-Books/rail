defmodule Rail.Tools.Actions.GetBrowserUrl do
  @moduledoc """
  Where a task's named browser is, if it has one and it has been anywhere.

  Chrome is the only thing that knows: the run's log says where the pass asked to
  go, which is not the same as where it ended up, and a panel reading the log
  only knows as far back as the part of it that it read.
  """

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Tools
  alias Rail.Tools.BrowserSession

  @doc """
  Returns the URL the browser `name` on `task` is on, or nil when there is no
  such browser or it has not navigated yet.
  """
  def get_browser_url(%Task{} = task, name) do
    case Tools.get_browser_session(task, name) do
      pid when is_pid(pid) -> BrowserSession.where(pid)
      nil -> nil
    end
  end
end
