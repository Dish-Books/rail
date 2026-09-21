defmodule Rail.Tools.Actions.GetBrowserSession do
  @moduledoc """
  The browser a task is being driven in, if it is being driven at all.

  Asking rather than starting: a caller that only wants to know whether a task has
  a browser - a panel drawing itself, a reconcile pass deciding what to reap -
  should not launch a Chrome by looking.
  """

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Tools.BrowserRegistry

  @doc """
  Returns the session process for `task`, or nil.
  """
  def get_browser_session(%Task{id: task_id}) do
    case Registry.lookup(BrowserRegistry, task_id) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  end
end
