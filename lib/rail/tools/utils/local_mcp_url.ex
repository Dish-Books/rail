defmodule Rail.Tools.Utils.LocalMcpUrl do
  @moduledoc false

  @doc """
  Rail's MCP server for an agent that shares Rail's host: one beside Rail, or a pass in a container on the host's
  network. A sandbox's runner names its own address instead. The public URL sits behind Cloudflare Access.
  """
  def local_mcp_url, do: "http://localhost:#{RailWeb.Endpoint.config(:http)[:port]}/mcp/internal"
end
