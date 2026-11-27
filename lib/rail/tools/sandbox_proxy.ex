defmodule Rail.Tools.SandboxProxy do
  @moduledoc """
  Answers the HTTP requests a sandbox's runner sends over its socket (docs/sandbox-socket.md): Claude Code's, which go
  on to Claude with the account's credential added here, and an agent's MCP calls, which Rail's own MCP server
  answers. Each runs in a process of its own and streams its answer to the socket as `{:http_head, ch, status,
  headers}`, `{:http_body, ch, bytes}` and finally `{:http_end, ch}`.
  """

  import Ecto.Query

  alias Rail.Mcp
  alias Rail.Mcp.RunContext
  alias Rail.Repo
  alias Rail.Tools.Claude
  alias Rail.Tools.Schemas.Backend
  alias Rail.Tools.Schemas.OsProcess

  @claude_paths ["/v1/messages", "/v1/messages/count_tokens"]
  @request_headers [
    "accept",
    "anthropic-beta",
    "anthropic-version",
    "content-type",
    "user-agent",
    "x-app",
    "x-claude-code-session-id",
    "x-stainless-retry-count",
    "x-stainless-timeout"
  ]
  @dropped_response_headers [
    "connection",
    "content-length",
    "content-encoding",
    "keep-alive",
    "set-cookie",
    "transfer-encoding"
  ]
  @oauth_beta "oauth-2025-04-20"
  @json [{"content-type", ["application/json"]}]

  @doc """
  Forwards one request of Claude Code in sandbox `sandbox_id` to Claude. Only an agent turn the runner gave a token to,
  running in that sandbox, reaches Claude, on the account the turn was placed on, and only for messages: nothing else
  of the account is reachable from a sandbox.
  """
  def claude(reply, ch, sandbox_id, %{"method" => method, "path" => path} = open, body) do
    with :ok <- claude_path(method, path),
         {:ok, backend} <- turn_backend(sandbox_id, open["proc"]),
         {:ok, token} <- token(backend) do
      forward(reply, ch, backend, token, open, body, true)
    else
      {:error, status, type, message} -> error(reply, ch, status, type, message)
    end

    send(reply, {:http_end, ch})
  end

  @doc """
  Answers one MCP request of an agent in sandbox `sandbox_id`, authenticated by its run token. A token whose turn runs
  in another sandbox is refused, so a sandbox can only act as its own turns.
  """
  def mcp(reply, ch, sandbox_id, %{"method" => method} = open, body) do
    case mcp_context(sandbox_id, open["headers"]) do
      {:ok, context} ->
        case {method, Jason.decode(body)} do
          {"POST", {:ok, message}} ->
            case Mcp.handle_rpc(context, message) do
              {202, nil} -> send(reply, {:http_head, ch, 202, []})
              {status, answer} -> respond(reply, ch, status, @json, Jason.encode!(answer))
            end

          {"POST", {:error, _invalid}} ->
            error(reply, ch, 400, "invalid_request_error", "The body is not JSON.")

          {_other, _body} ->
            send(reply, {:http_head, ch, 405, [{"allow", ["POST"]}]})
        end

      :error ->
        respond(reply, ch, 401, @json, Jason.encode!(%{"error" => "invalid_token"}))
    end

    send(reply, {:http_end, ch})
  end

  defp claude_path("POST", path) do
    if URI.parse(path).path in @claude_paths,
      do: :ok,
      else: {:error, 403, "permission_error", "Rail's Claude proxy forwards messages only, not #{path}."}
  end

  defp claude_path(method, path), do: {:error, 403, "permission_error", "Rail does not forward #{method} #{path}."}

  defp turn_backend(sandbox_id, proc) when is_binary(proc) do
    query =
      from p in OsProcess,
        where: p.id == ^proc and p.sandbox_id == ^sandbox_id and p.kind == :agent and p.status in [:starting, :running],
        preload: :backend

    case Repo.one(query) do
      %OsProcess{backend: %Backend{} = backend} -> {:ok, backend}
      _gone -> {:error, 401, "authentication_error", "That turn is not running in this sandbox."}
    end
  end

  defp turn_backend(_sandbox_id, _proc), do: {:error, 401, "authentication_error", "The request names no turn."}

  defp token(%Backend{} = backend) do
    case Claude.access_token(backend) do
      {:ok, token} -> {:ok, token}
      {:error, reason} -> {:error, 401, "authentication_error", "The account's login is unusable: #{inspect(reason)}"}
    end
  end

  # A 401 before anything was sent is answered by refreshing the login once and asking again.
  defp forward(reply, ch, backend, token, open, body, retry?) do
    config = Application.get_env(:rail, :claude_proxy, [])

    into = fn {:data, data}, {req, resp} ->
      cond do
        (retry? and resp.status == 401) or data == "" ->
          {:cont, {req, resp}}

        Req.Response.get_private(resp, :head_sent) ->
          send(reply, {:http_body, ch, data})
          {:cont, {req, resp}}

        true ->
          send(reply, {:http_head, ch, resp.status, response_headers(resp)})
          send(reply, {:http_body, ch, data})
          {:cont, {req, Req.Response.put_private(resp, :head_sent, true)}}
      end
    end

    result =
      Req.request(
        [
          method: :post,
          base_url: Keyword.get(config, :upstream, "https://api.anthropic.com"),
          url: open["path"],
          headers: request_headers(open["headers"], token),
          body: body,
          into: into,
          decode_body: false,
          compressed: false,
          retry: false,
          receive_timeout: to_timeout(minute: 10)
        ] ++ Keyword.get(config, :req_options, [])
      )

    case result do
      {:ok, %Req.Response{status: 401}} when retry? ->
        case Claude.refresh_access_token(backend, token) do
          {:ok, fresh} -> forward(reply, ch, backend, fresh, open, body, false)
          {:error, reason} -> error(reply, ch, 401, "authentication_error", "Rail could not refresh: #{inspect(reason)}")
        end

      {:ok, %Req.Response{} = resp} ->
        if !Req.Response.get_private(resp, :head_sent),
          do: send(reply, {:http_head, ch, resp.status, response_headers(resp)})

      {:error, exception} ->
        error(reply, ch, 502, "api_error", "Rail could not reach Claude: #{Exception.message(exception)}")
    end
  end

  defp request_headers(headers, token) when is_map(headers) do
    kept = for {name, values} <- headers, name in @request_headers, value <- List.wrap(values), do: {name, value}
    betas = for {"anthropic-beta", value} <- kept, beta <- String.split(value, ","), do: String.trim(beta)
    # The CLI sends the OAuth beta itself, signed in as a subscriber; a request that left it out still needs it.
    betas = if @oauth_beta in betas, do: betas, else: Enum.reverse([@oauth_beta | Enum.reverse(betas)])

    [
      {"anthropic-beta", Enum.join(betas, ",")},
      {"authorization", "Bearer #{token}"}
      | Enum.reject(kept, &match?({"anthropic-beta", _value}, &1))
    ]
  end

  defp request_headers(_headers, token), do: request_headers(%{}, token)

  defp response_headers(%Req.Response{headers: headers}) do
    for {name, values} <- headers, name not in @dropped_response_headers, do: {name, values}
  end

  defp mcp_context(sandbox_id, headers) do
    with %{"authorization" => ["Bearer " <> token | _rest]} <- headers,
         {:ok, %RunContext{os_process: %OsProcess{sandbox_id: ^sandbox_id}} = context} <-
           Mcp.authenticate_run_token(token) do
      {:ok, context}
    else
      _refused -> :error
    end
  end

  defp error(reply, ch, status, type, message) do
    respond(
      reply,
      ch,
      status,
      @json,
      Jason.encode!(%{"type" => "error", "error" => %{"type" => type, "message" => message}})
    )
  end

  defp respond(reply, ch, status, headers, body) do
    send(reply, {:http_head, ch, status, headers})
    send(reply, {:http_body, ch, body})
  end
end
