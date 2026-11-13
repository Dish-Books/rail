defmodule Rail.Mcp.Actions.RegisterDynamicClient do
  @moduledoc false

  alias Rail.Mcp.Schemas.OauthClient
  alias Rail.Repo

  @client_id_bytes 16
  @client_secret_bytes 32
  @auth_methods %{
    "none" => :none,
    "client_secret_basic" => :client_secret_basic,
    "client_secret_post" => :client_secret_post
  }

  @doc """
  Registers an MCP client from its RFC 7591 metadata. Returns `{:ok, client, secret}`, where a confidential client's
  secret is the only copy it will see and a public one's (`none`, the default) is nil.
  """
  def register_dynamic_client(%{} = metadata) do
    with {:ok, auth_method} <- auth_method(metadata),
         :ok <- validate_subset(metadata["grant_types"], ["authorization_code", "refresh_token"]),
         :ok <- validate_subset(metadata["response_types"], ["code"]) do
      secret =
        if auth_method != :none,
          do: Base.url_encode64(:crypto.strong_rand_bytes(@client_secret_bytes), padding: false)

      %{
        name: client_name(metadata["client_name"]),
        client_id: Base.url_encode64(:crypto.strong_rand_bytes(@client_id_bytes), padding: false),
        client_secret_hash: secret && :crypto.hash(:sha256, secret),
        redirect_uris: metadata["redirect_uris"],
        token_endpoint_auth_method: auth_method
      }
      |> OauthClient.dynamic_changeset()
      |> Repo.insert()
      |> case do
        {:ok, client} -> {:ok, client, secret}
        # Every other field is checked or generated above, so only the redirect URIs can fail here.
        {:error, _changeset} -> {:error, :invalid_redirect_uri}
      end
    end
  end

  defp auth_method(metadata) do
    case Map.fetch(@auth_methods, Map.get(metadata, "token_endpoint_auth_method", "none")) do
      {:ok, method} -> {:ok, method}
      :error -> {:error, :invalid_client_metadata}
    end
  end

  defp validate_subset(values, allowed) do
    cond do
      is_list(values) and values -- allowed == [] -> :ok
      is_nil(values) -> :ok
      true -> {:error, :invalid_client_metadata}
    end
  end

  defp client_name(name) when is_binary(name) do
    case String.trim(name) do
      "" -> "MCP client"
      name -> String.slice(name, 0, 100)
    end
  end

  defp client_name(_name), do: "MCP client"
end
