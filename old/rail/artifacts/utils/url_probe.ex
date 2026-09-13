defmodule Rail.Artifacts.Utils.UrlProbe do
  @moduledoc false

  @doc """
  Probes a canvas URL to check whether it can be opened.
  Returns false only for HTTP 404, 410, or network/connection failure.
  Returns true for any other HTTP response (200, 302, 401, 403, 500, etc.).
  Allows injecting a custom probe via `opts[:url_probe]`.
  """
  def probe(canvas_url, opts \\ []) when is_binary(canvas_url) do
    case Keyword.get(opts, :url_probe) do
      custom_probe when is_function(custom_probe, 1) ->
        custom_probe.(canvas_url)

      _default ->
        do_probe(canvas_url, opts)
    end
  end

  defp do_probe(canvas_url, opts) do
    req_options = Keyword.get(opts, :req_options, [])

    req =
      [receive_timeout: 10_000, connect_options: [timeout: 5000], retry: false]
      |> Req.new()
      |> Req.merge(req_options)

    case Req.head(req, url: canvas_url) do
      {:ok, %{status: status}} when status in [404, 410] ->
        false

      {:ok, %{status: 405}} ->
        case Req.get(req, url: canvas_url) do
          {:ok, %{status: status}} when status in [404, 410] -> false
          {:ok, _response} -> true
          {:error, _reason} -> false
        end

      {:ok, _response} ->
        true

      {:error, _reason} ->
        false
    end
  end
end
