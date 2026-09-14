defmodule Rail.Mcp.Actions.ListRunTools do
  @moduledoc false

  import Ecto.Query
  import Rail.Mcp.Utils.ToolAllowed
  import Rail.Mcp.Utils.WithUpstreamToken

  alias Rail.Mcp.Client
  alias Rail.Mcp.RunContext
  alias Rail.Mcp.Schemas.McpServer
  alias Rail.Repo

  require Logger

  @timeout to_timeout(second: 30)

  @doc """
  The tools a turn may call: every tool its role allows, on the enabled servers
  the issue's assigned user can reach, each renamed `<server name>__<tool>`.

  Servers are asked in parallel. One that fails, or that the user never
  connected, just contributes nothing — an agent is better off with the other
  servers' tools than with none.
  """
  def list_run_tools(%RunContext{role: %{mcp_tools: mcp_tools}, user: user}) do
    tools =
      mcp_tools
      |> allowed_servers()
      |> Task.async_stream(&server_tools(&1, mcp_tools, user), timeout: @timeout, on_timeout: :kill_task)
      |> Enum.flat_map(fn
        {:ok, tools} -> tools
        # coveralls-ignore-next-line (an upstream that outlives the timeout)
        {:exit, _reason} -> []
      end)

    {:ok, tools}
  end

  defp allowed_servers(mcp_tools) do
    names = mcp_tools |> Enum.map(&(&1 |> String.split("__", parts: 2) |> hd())) |> Enum.uniq()

    Repo.all(from s in McpServer, where: s.enabled and s.name in ^names, order_by: [asc: s.name])
  end

  defp server_tools(%McpServer{name: server_name} = server, mcp_tools, user) do
    case with_upstream_token(user, server, &Client.list_tools(server.url, &1)) do
      {:ok, tools} ->
        for %{"name" => tool_name} = tool <- tools, tool_allowed?(mcp_tools, server_name, tool_name) do
          Map.put(tool, "name", "#{server_name}__#{tool_name}")
        end

      {:error, reason} ->
        Logger.warning("[mcp] #{server_name} tools unavailable: #{inspect(reason)}")
        []
    end
  end
end
