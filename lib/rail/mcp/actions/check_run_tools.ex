defmodule Rail.Mcp.Actions.CheckRunTools do
  @moduledoc false

  import Rail.Mcp.Utils.AllowedServers
  import Rail.Mcp.Utils.WithUpstreamToken

  alias Rail.Mcp.Client
  alias Rail.Mcp.RunContext
  alias Rail.Mcp.Schemas.McpServer

  @timeout to_timeout(second: 30)

  @doc """
  Whether every server `context`'s role names tools on answers on its user's
  connection, for a run that must not go ahead without them.

  `list_run_tools/1` lets a server that fails contribute nothing; this is the
  same lookup asked strictly. Returns `:ok`, `{:error, {:mcp_reconnect, names}}`
  when a connection is missing or its token is spent, so only the user
  reconnecting fixes it, or `{:error, {:mcp_unreachable, names}}` when a server
  could not be reached at all.
  """
  def check_run_tools(%RunContext{role: %{mcp_tools: mcp_tools}, user: user}) do
    failures =
      mcp_tools
      |> allowed_servers()
      |> Task.async_stream(&{check(&1, user), &1.name},
        timeout: @timeout,
        on_timeout: :kill_task,
        zip_input_on_exit: true
      )
      |> Enum.flat_map(fn
        {:ok, {:ok, _name}} -> []
        {:ok, failure} -> [failure]
        # coveralls-ignore-next-line (an upstream that outlives the timeout)
        {:exit, {%McpServer{name: name}, _reason}} -> [{:unreachable, name}]
      end)

    cond do
      Enum.any?(failures, &match?({:reconnect, _name}, &1)) -> {:error, {:mcp_reconnect, names(failures, :reconnect)}}
      failures != [] -> {:error, {:mcp_unreachable, names(failures, :unreachable)}}
      true -> :ok
    end
  end

  defp check(%McpServer{} = server, user) do
    case with_upstream_token(user, server, &Client.list_tools(server.url, &1)) do
      {:ok, _tools} -> :ok
      {:error, reason} -> if reconnect?(reason), do: :reconnect, else: :unreachable
    end
  end

  # A refresh the token endpoint turns down is a grant that is gone, not an outage.
  defp reconnect?(reason) when reason in [:not_connected, :token_expired, :unauthorized], do: true
  defp reconnect?({:mcp_oauth_error, status, _body}) when status in [400, 401], do: true
  defp reconnect?(_reason), do: false

  defp names(failures, kind), do: for({^kind, name} <- failures, do: name)
end
