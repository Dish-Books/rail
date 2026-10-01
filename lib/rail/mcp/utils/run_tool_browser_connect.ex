defmodule Rail.Mcp.Utils.RunToolBrowserConnect do
  @moduledoc """
  Hands the agent its tab in the shared Chrome, and the driver to drive it with.

  The agent drives the page directly - its own scripts, its own DevTools
  connection, as many steps to a script as it likes - so what Rail hands over is
  an address and a file rather than a set of verbs. The tab is the task's, opened
  here if it is not open yet, and Rail keeps watching it for the panel, the
  recording and the problems it collects.

  The driver is copied into the task's scratch directory on every call, because
  that is a path both Rail and the agent's sandbox can see, and a release's
  `priv` is not.
  """

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Tools
  alias Rail.Tools.BrowserSession

  @doc """
  Opens or finds `task`'s tab and says how to reach it.
  """
  def run_tool_browser_connect(%Task{} = task, _arguments, opts) do
    with {:ok, session} <- Tools.start_browser_session(task, opts) do
      %{page_url: page_url} = BrowserSession.details(session)
      driver = Path.join([task.scratch_path, "browser", "driver.mjs"])
      File.mkdir_p!(Path.dirname(driver))
      File.cp!(Application.app_dir(:rail, "priv/browser/driver.mjs"), driver)

      {:ok,
       """
       Your tab: #{page_url}
       Now at: #{Tools.get_browser_url(task) || "about:blank"}
       Driver: #{driver}

       Write a script and run it with node:

       import { openBrowser } from '#{driver}'
       const b = await openBrowser('#{page_url}')
       await b.goto('http://localhost:PORT/') // your worktree's app
       await b.click(`document.querySelector('#save')`)
       console.log(await b.evaluate(`document.querySelector('h1')?.textContent`))
       for (const p of b.drainProblems()) console.log(`PROBLEM ${p.kind}: ${p.detail}`)
       await b.close()

       The driver's header lists everything it does. The tab stays where a script leaves it, signed in, for the next script. If the address stops answering, call browser_connect again.
       """}
    end
  end
end
