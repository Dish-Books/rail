defmodule Rail.Mcp.Utils.RunToolBrowserClose do
  @moduledoc """
  Closes the browser an agent is done with, and frees its place for the next.

  Rail closes a browser itself when the subagent that opened it returns, but only
  when it sees that happen: one working in the background answers as it starts,
  and its tab would otherwise stay open, holding one of the task's places, until
  the turn ends. So the agent says when it is done.

  Only a browser that is open is closed, so a slip in the name is said rather
  than read as done.
  """

  import Rail.Mcp.Utils.BrowserName

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Tools

  @doc """
  Closes the browser `arguments["browser"]` names on `task`, with its tab,
  context and sign-in.
  """
  def run_tool_browser_close(%Task{} = task, arguments, opts) do
    with {:ok, name} <- browser_name(arguments, opts) do
      if Enum.any?(Tools.list_browser_sessions(task), &(&1.name == name)) do
        :ok = Tools.stop_browser_session(task, name)

        {:ok, "Closed `#{name}`. Its tab and sign-in are gone; browser_connect with that name opens a new one."}
      else
        {:refused, "No browser named `#{name}` is open on this task, so nothing was closed."}
      end
    end
  end
end
