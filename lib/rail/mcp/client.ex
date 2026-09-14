defmodule Rail.Mcp.Client do
  @moduledoc """
  The one client for remote MCP servers: OAuth discovery, client registration
  and tokens, and the Streamable HTTP calls the proxy forwards.

  Like `Rail.Linear.Client`, it hands back what the server said. Every MCP
  operation opens its own session (`initialize`, `notifications/initialized`,
  then the request), so a token refreshed between two calls is simply the next
  call's token. A 401 comes back as `{:error, :unauthorized}` so the caller can
  refresh and try again.
  """

  @protocol_version "2025-06-18"
  @accept "application/json, text/event-stream"

  def config, do: Application.get_env(:rail, :mcp, [])

  def protocol_version, do: @protocol_version

  def redirect_uri, do: RailWeb.Endpoint.url() <> "/auth/mcp/callback"

  @doc """
  Knocks on the server without a token. Returns `{:ok, :open}` when it answers,
  or `{:ok, {:auth_required, resource_metadata_url}}` when it wants OAuth — the
  URL is the `resource_metadata` its `WWW-Authenticate` header named, or nil.
  """
  def probe(url, opts \\ []) do
    case Req.post(build_req(opts), url: url, headers: [{"accept", @accept}], json: initialize_message()) do
      {:ok, %{status: 401} = response} -> {:ok, {:auth_required, resource_metadata(response)}}
      {:ok, %{status: status}} when status in 200..299 -> {:ok, :open}
      {:ok, %{status: status, body: body}} -> {:error, {:mcp_http_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Fetches an OAuth metadata document: protected resource or authorization server.
  """
  def fetch_metadata(url, opts \\ []) do
    case Req.get(build_req(opts), url: url, retry: false) do
      {:ok, %{status: 200, body: %{} = body}} -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, {:mcp_metadata_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Registers Rail as an OAuth client (RFC 7591).
  """
  def register_client(registration_endpoint, opts \\ []) do
    metadata = %{
      client_name: "Rail",
      redirect_uris: [redirect_uri()],
      grant_types: ["authorization_code", "refresh_token"],
      response_types: ["code"],
      token_endpoint_auth_method: "none"
    }

    case Req.post(build_req(opts), url: registration_endpoint, json: metadata) do
      {:ok, %{status: status, body: %{"client_id" => _id} = body}} when status in 200..299 -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, {:mcp_registration_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Trades an authorization code and its PKCE verifier for tokens.
  """
  def exchange_code(server, code, verifier, opts \\ []) do
    form = [
      grant_type: "authorization_code",
      code: code,
      code_verifier: verifier,
      redirect_uri: redirect_uri()
    ]

    token_request(server, form, opts)
  end

  def refresh_token(server, refresh_token, opts \\ []) do
    token_request(server, [grant_type: "refresh_token", refresh_token: refresh_token], opts)
  end

  @doc """
  Lists every tool the server offers, following `nextCursor` to the end.
  """
  def list_tools(url, token, opts \\ []) do
    with {:ok, session} <- initialize(url, token, opts) do
      list_tool_pages(session, nil, [], opts)
    end
  end

  @doc """
  Calls one tool and returns its `CallToolResult`.
  """
  def call_tool(url, token, name, arguments, opts \\ []) do
    with {:ok, session} <- initialize(url, token, opts) do
      rpc(session, "tools/call", %{"name" => name, "arguments" => arguments}, opts)
    end
  end

  defp list_tool_pages(session, cursor, acc, opts) do
    params = if cursor, do: %{"cursor" => cursor}, else: %{}

    case rpc(session, "tools/list", params, opts) do
      {:ok, %{"nextCursor" => next} = result} when is_binary(next) and next != "" ->
        list_tool_pages(session, next, acc ++ (result["tools"] || []), opts)

      {:ok, result} ->
        {:ok, acc ++ (result["tools"] || [])}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp initialize(url, token, opts) do
    session = %{url: url, token: token, session_id: nil, protocol_version: @protocol_version}

    case post(session, initialize_message(), opts) do
      {:ok, response} ->
        with {:ok, result} <- rpc_result(response, 0) do
          session = %{
            session
            | session_id: header(response, "mcp-session-id"),
              protocol_version: result["protocolVersion"] || @protocol_version
          }

          notify(session, "notifications/initialized", opts)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp notify(session, method, opts) do
    with {:ok, _response} <- post(session, %{"jsonrpc" => "2.0", "method" => method}, opts) do
      {:ok, session}
    end
  end

  defp rpc(session, method, params, opts) do
    id = System.unique_integer([:positive])
    message = %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}

    with {:ok, response} <- post(session, message, opts) do
      rpc_result(response, id)
    end
  end

  defp post(session, message, opts) do
    headers =
      Enum.reject(
        [
          {"accept", @accept},
          {"mcp-protocol-version", session.protocol_version},
          {"mcp-session-id", session.session_id}
        ],
        fn {_name, value} -> is_nil(value) end
      )

    req_opts = [url: session.url, headers: headers, json: message]
    req_opts = if session.token, do: Keyword.put(req_opts, :auth, {:bearer, session.token}), else: req_opts

    case Req.post(build_req(opts), req_opts) do
      {:ok, %{status: status} = response} when status in 200..299 -> {:ok, response}
      {:ok, %{status: 401}} -> {:error, :unauthorized}
      {:ok, %{status: status, body: body}} -> {:error, {:mcp_http_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp rpc_result(response, id) do
    case Enum.find(messages(response.body), &(&1["id"] == id)) do
      %{"result" => result} -> {:ok, result}
      %{"error" => error} -> {:error, {:mcp_rpc_error, error}}
      _missing -> {:error, :mcp_no_response}
    end
  end

  defp messages(%{} = body), do: [body]
  defp messages(body) when is_binary(body), do: sse_messages(body)
  defp messages(_other), do: []

  # A Streamable HTTP server may answer a POST with an event stream that carries
  # the response (and possibly notifications before it) as `data:` lines.
  defp sse_messages(body) do
    body
    |> String.split(~r/\r?\n\r?\n/)
    |> Enum.flat_map(fn event ->
      data =
        event
        |> String.split(~r/\r?\n/)
        |> Enum.filter(&String.starts_with?(&1, "data:"))
        |> Enum.map_join("\n", &(&1 |> String.replace_prefix("data:", "") |> String.trim_leading()))

      case Jason.decode(data) do
        {:ok, %{} = message} -> [message]
        _not_json -> []
      end
    end)
  end

  defp token_request(server, form, opts) do
    form =
      form
      |> Keyword.put(:client_id, server.client_id)
      |> Keyword.put(:resource, server.resource || server.url)
      |> then(fn form ->
        if server.client_secret, do: Keyword.put(form, :client_secret, server.client_secret), else: form
      end)

    case Req.post(build_req(opts), url: server.token_endpoint, form: form) do
      {:ok, %{status: 200, body: %{"access_token" => _token} = body}} -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, {:mcp_oauth_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp initialize_message do
    %{
      "jsonrpc" => "2.0",
      "id" => 0,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => @protocol_version,
        "capabilities" => %{},
        "clientInfo" => %{"name" => "rail", "version" => "1.0.0"}
      }
    }
  end

  defp resource_metadata(response) do
    response
    |> header("www-authenticate")
    |> to_string()
    |> then(&Regex.run(~r/resource_metadata="([^"]+)"/, &1, capture: :all_but_first))
    |> case do
      [url] -> url
      _none -> nil
    end
  end

  defp header(response, name), do: response |> Req.Response.get_header(name) |> List.first()

  defp build_req(opts) do
    Req.new()
    |> Req.merge(Keyword.get(config(), :req_options, []))
    |> Req.merge(Keyword.get(opts, :req_options, []))
  end
end
