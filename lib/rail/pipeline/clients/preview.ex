defmodule Rail.Pipeline.Clients.Preview do
  @moduledoc """
  Asks a pull request's deployment which commit it runs, and lets Rail's browser past the Cloudflare Access in front of
  it, sending the service token only to the deployment's own address.
  """

  @doc "The commit the deployment at `url` serves, read from its `/version`: `{:ok, sha}` or `{:error, reason}`."
  def version(url, access) when is_binary(url) do
    case request(url <> "/version", access) do
      {:ok, %{status: 200, body: %{"sha" => "" <> sha}}} -> {:ok, sha}
      {:ok, %{status: status}} -> {:error, {:preview_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The cookies Rail's browser needs to reach `url` past Access: `{:ok, []}` without a token, or the
  `CF_Authorization` cookie Access sets for the service token, as `Network.setCookie` takes it.
  """
  def access_cookies(_url, nil), do: {:ok, []}

  def access_cookies(url, %{} = access) when is_binary(url) do
    %URI{host: host} = URI.parse(url)

    with {:ok, response} <- request(url <> "/version", access),
         "" <> value <- authorization(response) || {:error, :no_access_cookie} do
      {:ok, [%{name: "CF_Authorization", value: value, domain: host, path: "/", secure: true, httpOnly: true}]}
    end
  end

  defp authorization(%Req.Response{} = response) do
    response
    |> Req.Response.get_header("set-cookie")
    |> Enum.find_value(fn cookie ->
      case Regex.run(~r/\ACF_Authorization=([^;]+)/, cookie) do
        [_whole, value] -> value
        nil -> nil
      end
    end)
  end

  defp request(url, access) do
    headers =
      case access do
        %{client_id: id, client_secret: secret} -> [{"cf-access-client-id", id}, {"cf-access-client-secret", secret}]
        nil -> []
      end

    Req.get(
      [url: url, headers: headers, redirect: false, retry: false, receive_timeout: 10_000],
      :rail |> Application.get_env(:preview, []) |> Keyword.get(:req_options, [])
    )
  end
end
