defmodule Rail.Slack.Client do
  @moduledoc """
  The one client for Slack: the Web API a workspace's bot reads threads with,
  the Socket Mode handshake, and the OAuth a person links their account through.

  It makes the call and hands back what Slack said. Slack answers 200 with
  `"ok": false` when it refuses, so that is an error here rather than a body.
  """

  alias Rail.Projects.Schemas.SlackWorkspace

  @api_url "https://slack.com/api"
  @authorize_url "https://slack.com/oauth/v2/authorize"
  @page_size 200

  def auth_test(%SlackWorkspace{token: token}), do: get(token, "auth.test", [])

  @doc """
  Every public and private channel the bot can see, across all pages.
  """
  def list_channels(%SlackWorkspace{token: token}) do
    paginate(token, "conversations.list", [types: "public_channel,private_channel", exclude_archived: true], "channels")
  end

  @doc """
  Every message in the thread started at `thread_ts`, the parent first.
  """
  def replies(%SlackWorkspace{token: token}, channel, thread_ts) do
    paginate(token, "conversations.replies", [channel: channel, ts: thread_ts], "messages")
  end

  def user_info(%SlackWorkspace{token: token}, user_id) do
    with {:ok, %{"user" => user}} <- get(token, "users.info", user: user_id), do: {:ok, user}
  end

  def permalink(%SlackWorkspace{token: token}, channel, ts) do
    with {:ok, %{"permalink" => permalink}} <- get(token, "chat.getPermalink", channel: channel, message_ts: ts) do
      {:ok, permalink}
    end
  end

  @doc """
  Asks for a Socket Mode websocket URL, on the app-level token.
  """
  def open_connection(%SlackWorkspace{app_token: app_token}) do
    with {:ok, %{"url" => url}} <- request(:post, app_token, "apps.connections.open", []), do: {:ok, url}
  end

  @doc """
  Posts `text` in the thread, as whoever `user_token` belongs to.
  """
  def post_message(user_token, channel, thread_ts, text) do
    request(:post, user_token, "chat.postMessage", json: %{channel: channel, thread_ts: thread_ts, text: text})
  end

  def authorize_url(opts \\ []) do
    params =
      Enum.reject(
        [
          {"client_id", oauth_config()[:client_id]},
          {"user_scope", "chat:write"},
          {"redirect_uri", redirect_uri()},
          {"state", opts[:state]},
          {"team", opts[:team]}
        ],
        fn {_key, value} -> is_nil(value) end
      )

    @authorize_url <> "?" <> URI.encode_query(params)
  end

  def exchange_code(code) do
    cfg = oauth_config()

    form = [
      code: code,
      client_id: cfg[:client_id],
      client_secret: cfg[:client_secret],
      redirect_uri: redirect_uri()
    ]

    Req.new()
    |> Req.merge(Keyword.get(cfg, :req_options, []))
    |> Req.post(url: "#{@api_url}/oauth.v2.access", form: form)
    |> answer()
  end

  defp paginate(token, method, params, key, cursor \\ nil, acc \\ []) do
    params = if cursor, do: Keyword.put(params, :cursor, cursor), else: params

    with {:ok, body} <- get(token, method, Keyword.put(params, :limit, @page_size)) do
      acc = acc ++ Map.get(body, key, [])

      case get_in(body, ["response_metadata", "next_cursor"]) do
        next when is_binary(next) and next != "" -> paginate(token, method, params, key, next, acc)
        _last_page -> {:ok, acc}
      end
    end
  end

  defp get(token, method, params), do: request(:get, token, method, params: params)

  defp request(verb, token, method, opts) do
    [method: verb, url: "#{@api_url}/#{method}", auth: {:bearer, token}]
    |> Req.new()
    |> Req.merge(Keyword.get(config(), :req_options, []))
    |> Req.request(opts)
    |> answer()
  end

  defp answer({:ok, %{status: 200, body: %{"ok" => true} = body}}), do: {:ok, body}
  defp answer({:ok, %{status: 200, body: %{"error" => error}}}), do: {:error, {:slack_error, error}}
  defp answer({:ok, %{status: status}}), do: {:error, {:slack_error, status}}
  defp answer({:error, reason}), do: {:error, reason}

  defp config, do: Application.get_env(:rail, :slack, [])
  defp oauth_config, do: Application.get_env(:rail, :slack_oauth, [])
  defp redirect_uri, do: RailWeb.Endpoint.url() <> "/auth/slack/callback"
end
