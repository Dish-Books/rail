defmodule Rail.Mcp.Actions.AuthorizeUrl do
  @moduledoc false

  alias Rail.Mcp.Client
  alias Rail.Mcp.Schemas.McpServer

  @doc """
  Builds the authorization URL a user is sent to, with a fresh PKCE verifier.
  Returns `{:ok, url, verifier}`; the verifier stays with the user's session
  until the callback trades the code.
  """
  def authorize_url(%McpServer{authorization_endpoint: endpoint, client_id: client_id} = server, state)
      when is_binary(endpoint) and is_binary(client_id) do
    verifier = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    challenge = :sha256 |> :crypto.hash(verifier) |> Base.url_encode64(padding: false)

    params =
      [
        {"response_type", "code"},
        {"client_id", client_id},
        {"redirect_uri", Client.redirect_uri()},
        {"code_challenge", challenge},
        {"code_challenge_method", "S256"},
        {"state", state},
        {"resource", server.resource || server.url}
      ] ++ scope_param(server.scopes)

    separator = if String.contains?(endpoint, "?"), do: "&", else: "?"

    {:ok, endpoint <> separator <> URI.encode_query(params), verifier}
  end

  def authorize_url(_server, _state), do: {:error, :not_discovered}

  defp scope_param([_first | _rest] = scopes), do: [{"scope", Enum.join(scopes, " ")}]
  defp scope_param(_none), do: []
end
