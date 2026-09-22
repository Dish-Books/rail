defmodule Rail.Mcp.Utils.RunToolBrowserStop do
  @moduledoc """
  Closes the task's browser.

  Never required - Rail closes it when the task moves on - but it frees the
  machine sooner when the driving is finished. A task that has no browser open
  is not an error: there is nothing to close and that is the state asked for.
  """

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Tools

  @doc """
  Closes `task`'s browser, whether or not it had one.
  """
  def run_tool_browser_stop(%Task{} = task, _arguments, _opts) do
    :ok = Tools.stop_browser_session(task)

    {:ok, "The browser is closed."}
  end
end
