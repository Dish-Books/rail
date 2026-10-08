defmodule Rail.Mcp.Utils.RunToolBrowserProblems do
  @moduledoc """
  Everything the browser complained about since it was last asked.

  Draining rather than accumulating, so what comes back belongs to the check that
  just ran. A console error found after step 40 that was actually thrown on step
  2 is worse than no console error at all.

  Each one says where it happened where the browser said: "something 404'd" is
  not a finding anybody can act on.
  """

  import Rail.Mcp.Utils.NamedBrowser

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Tools.BrowserSession

  @doc """
  Returns what the browser `arguments["browser"]` names on `task` has complained
  about, and forgets it.
  """
  def run_tool_browser_problems(%Task{} = task, arguments, opts) do
    with {:ok, _name, session} <- named_browser(task, arguments, opts) do
      drained(BrowserSession.drain_problems(session))
    end
  end

  defp drained([]), do: {:ok, "Nothing since the last check."}

  defp drained(problems) do
    {:ok, Enum.map_join(problems, "\n", &"[#{&1.kind}] #{&1.detail}#{where(&1)}")}
  end

  defp where(%{url: url}) when is_binary(url) and url != "", do: " (#{url})"
  defp where(_problem), do: ""
end
