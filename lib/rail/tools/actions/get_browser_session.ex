defmodule Rail.Tools.Actions.GetBrowserSession do
  @moduledoc """
  The browser an agent named on a task, if it is being driven at all.

  Asking rather than starting: a caller that only wants to know whether a task has
  a browser - a panel drawing itself, a reconcile pass deciding what to reap -
  should not launch a Chrome by looking.
  """

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Tools.BrowserRegistry

  @doc """
  Returns the session process for the browser `name` on `task`, or nil.
  """
  def get_browser_session(%Task{id: task_id}, name) do
    # The registry drops a session only once it has seen it exit, so for a moment
    # after one stops, the lookup still names it.
    case Registry.lookup(BrowserRegistry, {task_id, name}) do
      [{pid, _value}] -> if Process.alive?(pid), do: pid
      [] -> nil
    end
  end
end
