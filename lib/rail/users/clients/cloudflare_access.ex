defmodule Rail.Users.Clients.CloudflareAccess do
  @moduledoc """
  Reads the public keys a Cloudflare Access team signs its tokens with.
  """

  @doc "The team's current signing keys, as JWK maps."
  def certs(team_domain) when is_binary(team_domain) do
    options = :rail |> Application.get_env(:cloudflare_access, []) |> Keyword.get(:req_options, [])

    case Req.get("https://#{team_domain}/cdn-cgi/access/certs", options) do
      {:ok, %{status: 200, body: %{"keys" => keys}}} when is_list(keys) -> {:ok, keys}
      {:ok, %{status: status, body: body}} -> {:error, {:cloudflare_access_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end
end
