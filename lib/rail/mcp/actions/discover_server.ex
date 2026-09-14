defmodule Rail.Mcp.Actions.DiscoverServer do
  @moduledoc false

  alias Rail.Mcp.Client
  alias Rail.Mcp.Schemas.McpServer
  alias Rail.Repo

  @doc """
  Works out how to authenticate to the server and stores it.

  An unauthenticated `initialize` that succeeds means the server needs no
  account. A 401 starts MCP authorization discovery: the protected resource
  metadata (from `WWW-Authenticate`, else the well-known paths) names the
  authorization server, whose metadata gives the endpoints. Rail then registers
  itself through dynamic client registration, once — a server that already has a
  client keeps it.
  """
  def discover_server(_scope, %McpServer{} = server) do
    case Client.probe(server.url) do
      {:ok, :open} -> save(server, %{auth: :none})
      {:ok, {:auth_required, metadata_url}} -> discover_oauth(server, metadata_url)
      {:error, reason} -> {:error, reason}
    end
  end

  defp discover_oauth(server, metadata_url) do
    protected = find_metadata([metadata_url | well_known(server.url, "oauth-protected-resource")]) || %{}
    issuer = List.first(protected["authorization_servers"] || []) || origin(server.url)

    with {:ok, authorization_server} <- authorization_server(issuer) do
      attrs = %{
        auth: :oauth,
        resource: protected["resource"] || server.url,
        authorization_endpoint: authorization_server["authorization_endpoint"],
        token_endpoint: authorization_server["token_endpoint"],
        registration_endpoint: authorization_server["registration_endpoint"],
        scopes: protected["scopes_supported"] || []
      }

      with {:ok, client} <- client(server, attrs.registration_endpoint) do
        save(server, Map.merge(attrs, client))
      end
    end
  end

  defp authorization_server(issuer) do
    candidates =
      Enum.concat([
        well_known(issuer, "oauth-authorization-server"),
        well_known(issuer, "openid-configuration"),
        [String.trim_trailing(issuer, "/") <> "/.well-known/openid-configuration"]
      ])

    case find_metadata(candidates) do
      %{"authorization_endpoint" => _authorize, "token_endpoint" => _token} = metadata -> {:ok, metadata}
      _missing -> {:error, :authorization_server_not_found}
    end
  end

  defp client(%McpServer{client_id: client_id}, _endpoint) when is_binary(client_id), do: {:ok, %{}}
  defp client(_server, endpoint) when is_binary(endpoint), do: register(endpoint)
  defp client(_server, _endpoint), do: {:error, :no_registration_endpoint}

  defp register(endpoint) do
    with {:ok, registration} <- Client.register_client(endpoint) do
      {:ok, %{client_id: registration["client_id"], client_secret: registration["client_secret"]}}
    end
  end

  defp find_metadata(candidates) do
    candidates
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Enum.find_value(fn url ->
      case Client.fetch_metadata(url) do
        {:ok, metadata} -> metadata
        {:error, _reason} -> nil
      end
    end)
  end

  # RFC 8414 / RFC 9728 insert the well-known segment between the origin and the
  # path; the bare origin form is the fallback for servers that ignore the path.
  defp well_known(url, name) do
    %URI{path: path} = URI.parse(url)
    path = String.trim_trailing(path || "", "/")

    Enum.uniq([
      origin(url) <> "/.well-known/" <> name <> path,
      origin(url) <> "/.well-known/" <> name
    ])
  end

  defp origin(url) do
    %URI{scheme: scheme, host: host, port: port} = URI.parse(url)
    URI.to_string(%URI{scheme: scheme, host: host, port: port})
  end

  defp save(server, attrs) do
    server
    |> McpServer.changeset(attrs)
    |> Repo.update()
  end
end
