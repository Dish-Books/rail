defmodule Rail.Mcp.Utils.FetchClient do
  @moduledoc """
  The registered client a `client_id` names. One that is an https URL with a path is a client ID metadata document,
  fetched, checked and stored, then reused for a day.
  """

  import Ecto.Query

  alias Rail.Mcp.Client
  alias Rail.Mcp.Schemas.OauthClient
  alias Rail.Repo

  @metadata_ttl_seconds 86_400
  @max_document_bytes 5_120

  @doc "Returns `{:ok, client}`, or `{:error, :invalid_client}` for an unknown client or a document Rail cannot trust."
  def fetch_client(client_id) when is_binary(client_id) do
    if metadata_document_url?(client_id) do
      fetch_metadata_document_client(client_id)
    else
      case Repo.get_by(OauthClient, client_id: client_id) do
        %OauthClient{} = client -> {:ok, client}
        nil -> {:error, :invalid_client}
      end
    end
  end

  def fetch_client(_client_id), do: {:error, :invalid_client}

  defp fetch_metadata_document_client(url) do
    client = Repo.one(from c in OauthClient, where: c.client_id == ^url and c.registration == :metadata_document)

    if fresh?(client) do
      {:ok, client}
    else
      with {:ok, document} <- fetch_document(url) do
        (client || %OauthClient{})
        |> OauthClient.metadata_document_changeset(%{
          client_id: url,
          name: String.slice(document["client_name"], 0, 100),
          redirect_uris: document["redirect_uris"],
          metadata_fetched_at: DateTime.utc_now()
        })
        |> Repo.insert_or_update()
        |> case do
          {:ok, client} -> {:ok, client}
          {:error, _changeset} -> {:error, :invalid_client}
        end
      end
    end
  end

  defp fetch_document(url) do
    %URI{host: host} = URI.parse(url)

    with :ok <- public_host(host),
         {:ok, %Req.Response{status: 200, body: body}} when byte_size(body) <= @max_document_bytes <-
           Req.get(url, request_options()),
         {:ok, %{"client_id" => ^url, "client_name" => name, "redirect_uris" => [_first | _rest]} = document}
         when is_binary(name) and name != "" <- Jason.decode(body),
         true <- document["token_endpoint_auth_method"] in [nil, "none"] do
      {:ok, document}
    else
      _untrusted -> {:error, :invalid_client}
    end
  end

  defp request_options do
    Keyword.merge(
      [redirect: false, retry: false, receive_timeout: 5_000, decode_body: false, into: &collect_capped/2],
      Keyword.get(Client.config(), :req_options, [])
    )
  end

  # Stops reading past the cap, so a host that streams forever cannot exhaust memory.
  defp collect_capped({:data, data}, {request, response}) do
    response = %{response | body: response.body <> data}

    if byte_size(response.body) > @max_document_bytes,
      do: {:halt, {request, response}},
      else: {:cont, {request, response}}
  end

  # The document may only come from a host that resolves to public addresses, so a client cannot aim Rail at its own network.
  defp public_host(host) do
    charlist = String.to_charlist(host)

    addresses =
      Enum.flat_map([:inet, :inet6], fn family ->
        case :inet.getaddrs(charlist, family) do
          {:ok, addresses} -> addresses
          {:error, _reason} -> []
        end
      end)

    if addresses != [] and Enum.all?(addresses, &public_address?/1), do: :ok, else: {:error, :invalid_client}
  end

  defp public_address?({a, b, _c, _d}) do
    not (a in [0, 10, 127] or (a == 169 and b == 254) or (a == 172 and b in 16..31) or (a == 192 and b == 168) or
           (a == 100 and b in 64..127) or a >= 224)
  end

  defp public_address?({a, _b, _c, _d, _e, _f, _g, _h} = address) do
    not (address in [{0, 0, 0, 0, 0, 0, 0, 0}, {0, 0, 0, 0, 0, 0, 0, 1}] or Bitwise.band(a, 0xFE00) == 0xFC00 or
           Bitwise.band(a, 0xFFC0) == 0xFE80 or Bitwise.band(a, 0xFF00) == 0xFF00 or
           match?({0, 0, 0, 0, 0, 0xFFFF, _g, _h}, address))
  end

  defp metadata_document_url?(client_id) do
    case URI.parse(client_id) do
      %URI{scheme: "https", host: host, path: path, fragment: nil, userinfo: nil}
      when is_binary(host) and host != "" and is_binary(path) and path != "/" ->
        true

      _other ->
        false
    end
  end

  defp fresh?(%OauthClient{metadata_fetched_at: %DateTime{} = fetched_at}),
    do: DateTime.diff(DateTime.utc_now(), fetched_at) < @metadata_ttl_seconds

  defp fresh?(_client), do: false
end
