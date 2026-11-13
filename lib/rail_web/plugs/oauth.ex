defmodule RailWeb.Plugs.OAuth do
  @moduledoc """
  Resolves the bearer token a person's Claude sends to `/mcp` to their `Rail.Scope`, assigned as `current_scope`. A
  missing or bad token gets a 401 whose challenge names the protected-resource metadata, so Claude can find where to sign in.
  """

  import Plug.Conn

  alias Rail.Mcp

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> token] when byte_size(token) > 0 <- get_req_header(conn, "authorization"),
         {:ok, scope} <- Mcp.resolve_access_token(token) do
      assign(conn, :current_scope, scope)
    else
      {:error, reason} -> deny(conn, reason)
      _missing -> deny(conn, :missing_token)
    end
  end

  defp deny(conn, reason) do
    description =
      case reason do
        :expired -> "the access token expired"
        :revoked -> "the access token was revoked"
        :missing_token -> "no bearer token supplied"
        :invalid_token -> "the access token is invalid"
        :github_required -> "connect GitHub in Rail to use its tools"
      end

    metadata_url = RailWeb.Endpoint.url() <> "/.well-known/oauth-protected-resource/mcp"

    conn
    |> put_resp_header(
      "www-authenticate",
      ~s(Bearer error="invalid_token", error_description="#{description}", scope="mcp", resource_metadata="#{metadata_url}")
    )
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{error: "invalid_token", error_description: description}))
    |> halt()
  end
end
