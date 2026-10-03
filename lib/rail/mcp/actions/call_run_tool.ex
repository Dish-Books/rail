defmodule Rail.Mcp.Actions.CallRunTool do
  @moduledoc """
  Runs one tool for a turn, whoever holds it.

  `Rail.Mcp.Utils.McpTools.mcp_tools/1` says which tools Rail serves this run
  itself. Anything else is a proxied name (`<server name>__<tool>`), forwarded to
  its server on the issue's assigned user's connection.

  That register is the whole of the gate, so there is no second idea of who may
  call what: a review run calling `browser_connect` was offered no such tool, falls
  through to the proxy, and finds no server by that name either. The allowlist is
  rechecked here rather than trusted from `tools/list`, because an agent can call
  any name it likes.

  Each tool Rail serves is a `Rail.Mcp.Utils.RunTool*` of its own, so what is
  here is the dispatch and the log. Each call is logged as it is made rather than
  when it returns, so a run can be watched while it is still going. The page
  itself is driven by the agent's own scripts, which Rail does not see; what the
  panel shows of that is the tab.

  A line is filed under the namespace of the tool that wrote it - `[browser]`,
  `[qa]`, `[demo]` - because the panels read the log back for different reasons
  and the prefix is what separates driving the page from reporting on it.
  """

  import Rail.Mcp.Utils.McpTools
  import Rail.Mcp.Utils.RunToolBrowserConnect
  import Rail.Mcp.Utils.RunToolBrowserProblems
  import Rail.Mcp.Utils.RunToolDemoSay
  import Rail.Mcp.Utils.RunToolDemoStart
  import Rail.Mcp.Utils.RunToolKnowledgeSearch
  import Rail.Mcp.Utils.RunToolQaCheck
  import Rail.Mcp.Utils.RunToolQaFile
  import Rail.Mcp.Utils.RunToolQaPlan
  import Rail.Mcp.Utils.RunToolQaShot
  import Rail.Mcp.Utils.ToolAllowed
  import Rail.Mcp.Utils.WithUpstreamToken

  alias Rail.Mcp.Client
  alias Rail.Mcp.RunContext
  alias Rail.Mcp.Schemas.McpServer
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc """
  Runs `name` for `context` and returns what the agent should read.
  """
  def call_run_tool(%RunContext{} = context, name, arguments) when is_binary(name) do
    if Enum.any?(mcp_tools(context.role), &(&1["name"] == name)) do
      own(context, name, arguments)
    else
      proxy(context, name, arguments)
    end
  end

  def call_run_tool(_context, _name, _arguments), do: {:error, :unknown_tool}

  # The knowledge base is the project's, not a task's, so a triage pass with no task can search it.
  defp own(%RunContext{role: role} = context, "knowledge_search" = name, arguments) do
    arguments = arguments || %{}
    log(context, name, asked(name, arguments))

    {:ok, text} = run_tool_knowledge_search(role, arguments, [])
    {:ok, %{"content" => [%{"type" => "text", "text" => text}]}}
  end

  defp own(%RunContext{} = context, name, arguments) do
    arguments = arguments || %{}
    line = asked(name, arguments)

    with {:ok, task} <- task(context) do
      if not answers_itself?(name), do: log(context, name, line)

      result = run(name, task, arguments, [])

      if answers_itself?(name), do: log(context, name, said(name, line, result))

      case result do
        {:ok, text} -> {:ok, %{"content" => [%{"type" => "text", "text" => text}]}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # Everything says what it is doing before it does it, because a tab that takes
  # ten seconds to open is ten seconds of a person watching nothing happen.
  #
  # Five are the exception, for three reasons. The checklist and filing lines tell
  # the panel to read again, so one written first arrives before there is
  # anything to read. A call whose arguments say nothing - `browser_problems`
  # takes none - has nothing to log until it has an answer. And a caption is only
  # worth reading beside the time it was stamped at, which the tool works out.
  defp answers_itself?(name), do: name in ["qa_plan", "qa_check", "qa_file", "browser_problems", "demo_say"]

  # What the browser complained about, counted rather than quoted: the agent has
  # the list, and a watcher wants to know whether there was one.
  defp said("browser_problems", line, {:ok, text}) do
    case String.split(String.trim(text), "\n", trim: true) do
      ["Nothing since the last check."] -> line <> " none"
      problems -> "#{line} #{length(problems)} · #{hd(problems)}"
    end
  end

  # The caption is the agent's and the timestamp is Rail's, so the log carries the
  # words with the moment they landed on rather than the receipt the agent read.
  defp said("demo_say", line, {:ok, "Said at " <> said}), do: "#{hd(String.split(said, "."))} #{line}"

  # A refusal is a call that filed nothing, and a run log of them should not read
  # as a run of files filed.
  defp said("qa_file", line, {:ok, text}) do
    if String.ends_with?(text, "Nothing was filed."), do: line <> " · nothing filed", else: line
  end

  defp said(_name, line, _result), do: line

  defp proxy(%RunContext{role: %{mcp_tools: mcp_tools}, user: user}, name, arguments) do
    with [server_name, tool] <- String.split(name, "__", parts: 2),
         true <- tool_allowed?(mcp_tools, server_name, tool),
         %McpServer{} = server <- Repo.get_by(McpServer, name: server_name, enabled: true) do
      with_upstream_token(user, server, &Client.call_tool(server.url, &1, tool, arguments || %{}))
    else
      _not_allowed -> {:error, :unknown_tool}
    end
  end

  defp asked("qa_plan", %{"checks" => checks}) when is_list(checks), do: "plan #{length(checks)} checks"
  defp asked("qa_check", %{"key" => key, "outcome" => outcome}), do: "check #{inspect(key)} #{outcome}"
  defp asked("qa_shot", %{"name" => name}), do: "shot #{inspect(name)}"
  defp asked("qa_file", %{"name" => name}), do: "file #{inspect(name)}"
  defp asked("demo_say", %{"text" => text}), do: "say #{inspect(text)}"
  defp asked("demo_say", _arguments), do: "say"
  defp asked("knowledge_search", %{"query" => query}), do: "search #{inspect(query)}"
  defp asked(name, _arguments), do: name |> String.split("_", parts: 2) |> List.last()

  # A run that has not started has nowhere to write, which is every call made
  # while testing this rather than during a pass.
  defp log(%RunContext{os_process: %{run_id: run_id}}, name, line) when is_binary(run_id) do
    Pipeline.append_run_events(run_id, nil, ["[#{namespace(name)}] " <> line])

    :ok
  end

  defp log(%RunContext{}, _name, _line), do: :ok

  # Every tool Rail serves is named `<namespace>_<verb>`, and the namespace is
  # what the log is filed under.
  defp namespace(name), do: name |> String.split("_", parts: 2) |> hd()

  # Each of these owns whatever it needs, the browser included: the ones that are
  # about the pass rather than the page never open one, and a pass that writes
  # its checklist and then stops has still told the human what it meant to do.
  defp run("browser_connect", task, arguments, opts), do: run_tool_browser_connect(task, arguments, opts)
  defp run("browser_problems", task, arguments, opts), do: run_tool_browser_problems(task, arguments, opts)
  defp run("qa_plan", task, arguments, opts), do: run_tool_qa_plan(task, arguments, opts)
  defp run("qa_check", task, arguments, opts), do: run_tool_qa_check(task, arguments, opts)
  defp run("qa_shot", task, arguments, opts), do: run_tool_qa_shot(task, arguments, opts)
  defp run("qa_file", task, arguments, opts), do: run_tool_qa_file(task, arguments, opts)
  defp run("demo_start", task, arguments, opts), do: run_tool_demo_start(task, arguments, opts)
  defp run("demo_say", task, arguments, opts), do: run_tool_demo_say(task, arguments, opts)

  defp task(%RunContext{os_process: %{task_id: task_id}}) when is_binary(task_id) do
    case Pipeline.get_task(task_id) do
      {:ok, %Task{} = task} -> {:ok, task}
      {:error, :not_found} -> {:error, :no_task}
    end
  end

  defp task(%RunContext{}), do: {:error, :no_task}
end
