defmodule Rail.Mcp.Utils.RunToolBrowserGoto do
  @moduledoc """
  Opens a URL in the task's browser and says where it ended up.

  Where it ended up is not always where it was sent - a login redirect, a
  canonical path, a route that bounced - and an agent that assumed otherwise
  would be working on the wrong screen. The page is read once it has settled
  rather than the instant navigation returns, because a document mid-render has
  no title yet.
  """

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Tools
  alias Rail.Tools.BrowserSession

  # Long enough for the first paint of an ordinary page, short enough that a
  # check does not feel like it stalled.
  @settle_ms 200

  @doc """
  Navigates `task`'s browser to the URL in `arguments` and reports the page it
  reached, opening the browser if this is the first call of the pass.
  """
  def run_tool_browser_goto(%Task{} = task, %{"url" => url}, opts) do
    with {:ok, session} <- Tools.start_browser_session(task, opts),
         {:ok, _navigated} <- BrowserSession.call(session, "Page.navigate", %{url: url}),
         {:ok, page} <- settle(session) do
      {:ok, "Opened #{page["url"]} - #{page["title"]}"}
    end
  end

  defp settle(session) do
    Process.sleep(@settle_ms)

    Tools.observe_browser(session)
  end
end
