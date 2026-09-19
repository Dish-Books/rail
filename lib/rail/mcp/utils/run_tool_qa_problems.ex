defmodule Rail.Mcp.Utils.RunToolQaProblems do
  @moduledoc """
  Everything the browser complained about since it was last asked.

  Draining rather than accumulating, so what comes back belongs to the check that
  just ran. A console error found after step 40 that was actually thrown on step
  2 is worse than no console error at all.

  Each one says where it happened where the browser said: "something 404'd" is
  not a finding anybody can act on.
  """

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Tools
  alias Rail.Tools.BrowserSession

  @doc """
  Returns what `task`'s browser has complained about, and forgets it.
  """
  def run_tool_qa_problems(%Task{} = task, _arguments, opts) do
    with {:ok, session} <- Tools.start_browser_session(task, opts) do
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
