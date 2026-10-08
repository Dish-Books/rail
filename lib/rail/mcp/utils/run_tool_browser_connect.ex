defmodule Rail.Mcp.Utils.RunToolBrowserConnect do
  @moduledoc """
  Hands the agent a tab in the shared Chrome, and the driver to drive it with.

  The agent drives the page directly - its own scripts, its own DevTools
  connection, as many steps to a script as it likes - so what Rail hands over is
  an address and a file rather than a set of verbs. Each name the agent gives is
  a browser context and tab of its own, opened here if it is not open yet, and
  Rail keeps watching it for the panel, the recording and the problems it collects.

  A name's first connect signs its tab in as a fresh account when the project has
  an account seed: the seed runs once in the agent's own sandbox, and the last link
  it prints is opened in the tab, so no two browsers share an account or its data.

  The driver is copied into the task's scratch directory on every call, because
  that is a path both Rail and the agent's sandbox can see, and a release's
  `priv` is not.
  """

  import Rail.Mcp.Utils.BrowserName

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Tools
  alias Rail.Tools.BrowserSession

  @doc """
  Opens or finds the browser `arguments["browser"]` names on `task`, signs a new
  one in as `arguments["account"]` asks, and says how to reach it.
  """
  def run_tool_browser_connect(%Task{} = task, arguments, opts) do
    with {:ok, name} <- browser_name(arguments, opts),
         {:ok, account} <- account(arguments),
         {:ok, session} <- Tools.start_browser_session(task, name, opts),
         {:ok, signed_in} <- sign_in(task, session, account, opts) do
      %{page_url: page_url} = BrowserSession.details(session)
      driver = Path.join([task.scratch_path, "browser", "driver.mjs"])
      File.mkdir_p!(Path.dirname(driver))
      File.cp!(Application.app_dir(:rail, "priv/browser/driver.mjs"), driver)

      {:ok,
       """
       Browser: #{name}
       Your tab: #{page_url}
       Now at: #{Tools.get_browser_url(task, name) || "about:blank"}
       #{signed_in}#{no_seed(task)}Driver: #{driver}

       Write a script and run it with node:

       import { openBrowser } from '#{driver}'
       const b = await openBrowser('#{page_url}')
       await b.goto('http://localhost:PORT/') // your worktree's app
       await b.click(`document.querySelector('#save')`)
       console.log(await b.evaluate(`document.querySelector('h1')?.textContent`))
       for (const p of b.drainProblems()) console.log(`PROBLEM ${p.kind}: ${p.detail}`)
       await b.close()

       The driver's header lists everything it does. The tab stays where a script leaves it, signed in, for the next script. If the address stops answering, call browser_connect again with the same `browser`.
       """}
    end
  end

  # Said outright rather than left to the absence of an account, which also means a
  # bare browser or a seed that printed no email.
  defp no_seed(%Task{project: %Project{account_seed_command: seed}}) when seed in [nil, ""],
    do: "Account seed: none, so sign in as your prompt says.\n"

  defp no_seed(%Task{}), do: ""

  defp account(arguments) do
    case Map.get(arguments, "account", "fresh") do
      account when account in ["fresh", "bare"] -> {:ok, account}
      _other -> {:refused, "`account` is `fresh` or `bare`. Nothing was opened."}
    end
  end

  # Only a tab nobody has signed in yet is signed in, so a reconnect, or a tab found
  # again after a restart, keeps whoever it already is whatever `account` asks.
  defp sign_in(%Task{project: %Project{account_seed_command: seed}}, session, account, opts) do
    case BrowserSession.details(session) do
      %{signed_in?: true, account: "" <> email} when account == "bare" ->
        {:ok, said(email) <> "`bare` only opens a new browser, so ask under a new name for one with nobody signed in.\n"}

      %{signed_in?: true, account: email} ->
        {:ok, said(email)}

      %{signed_in?: false} when account == "bare" or seed in [nil, ""] ->
        settle(session, nil, nil)

      %{signed_in?: false} ->
        seed(session, seed, Keyword.fetch!(opts, :os_process))
    end
  end

  defp seed(session, seed, os_process) do
    with {:ok, %{exit_code: 0, output: output}} <- Tools.run_in_sandbox(os_process, seed),
         "" <> link <- link(output) || {:no_link, output} do
      settle(session, link, email(output))
    else
      {:no_link, output} ->
        {:refused, "The account seed `#{seed}` printed no link to sign in with. It printed:\n#{tail(output)}"}

      {:ok, %{exit_code: code, output: output}} ->
        {:refused, "The account seed `#{seed}` exited with #{code}, so nobody is signed in. It printed:\n#{tail(output)}"}

      {:error, :timeout} ->
        {:refused, "The account seed `#{seed}` did not finish within two minutes, so nobody is signed in."}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp settle(session, link, email) do
    with :ok <- BrowserSession.sign_in(session, link, email), do: {:ok, said(email)}
  end

  defp said("" <> email), do: "Signed in as: #{email}, an account of this browser's own\n"
  defp said(nil), do: ""

  # The link is the last one printed, since a seed that logs what it is doing
  # prints its own paths on the way, and a sentence's full stop is not part of it.
  defp link(output) do
    case Regex.scan(~r{https?://[^\s"'<>]+}, output) do
      [] -> nil
      links -> links |> List.last() |> hd() |> String.trim_trailing(".") |> String.trim_trailing(",")
    end
  end

  defp email(output) do
    case Regex.run(~r/[\w.+-]+@[\w-]+(?:\.[\w-]+)+/u, output) do
      [email] -> email
      nil -> nil
    end
  end

  defp tail(output), do: output |> String.split("\n") |> Enum.take(-20) |> Enum.join("\n") |> String.slice(-2_000..-1//1)
end
