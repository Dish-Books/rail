defmodule Rail.Mcp.Utils.WithUpstreamToken do
  @moduledoc false

  alias Rail.Mcp

  @doc """
  Calls `fun` with the user's token for `server`. When the server rejects it
  anyway — revoked early, or a clock that disagrees with `expires_at` — the
  token is refreshed and `fun` gets exactly one more try.
  """
  def with_upstream_token(user, server, fun) do
    with {:ok, token} <- Mcp.mcp_token(user, server) do
      case fun.(token) do
        {:error, :unauthorized} -> retry(user, server, fun)
        result -> result
      end
    end
  end

  defp retry(user, server, fun) do
    with {:ok, token} <- Mcp.mcp_token(user, server, force: true) do
      fun.(token)
    end
  end
end
