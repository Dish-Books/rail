defmodule Rail.Issues.Clients.R2 do
  @moduledoc """
  Puts and gets one object in Rail's private Cloudflare R2 bucket, over R2's S3 API with Req's own SigV4 signing.
  """

  @doc "Stores `body` under `key` as `content_type`."
  def put_object(key, content_type, body) when is_binary(key) and is_binary(body) do
    case request(method: :put, url: key, headers: [content_type: content_type], body: body) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: status, body: body}} -> {:error, {:r2_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "The object under `key`, as `{:ok, content_type, body}`, or `{:error, :not_found}`."
  def get_object(key) when is_binary(key) do
    case request(method: :get, url: key) do
      {:ok, %{status: 200} = response} -> {:ok, content_type(response), response.body}
      {:ok, %{status: 404}} -> {:error, :not_found}
      {:ok, %{status: status, body: body}} -> {:error, {:r2_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp request(options) do
    config = Application.get_env(:rail, :r2, [])

    [
      base_url: "https://#{config[:account_id]}.r2.cloudflarestorage.com/#{config[:bucket]}",
      aws_sigv4: [
        access_key_id: config[:access_key_id],
        secret_access_key: config[:secret_access_key],
        service: :s3,
        region: "auto"
      ],
      decode_body: false
    ]
    |> Keyword.merge(options)
    |> Req.request(Keyword.get(config, :req_options, []))
  end

  defp content_type(%{headers: %{"content-type" => [type | _rest]}}), do: type
  defp content_type(_unsaid), do: "application/octet-stream"
end
