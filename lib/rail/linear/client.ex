defmodule Rail.Linear.Client do
  @moduledoc """
  HTTP and GraphQL client for Linear OAuth and API operations.
  """

  @default_authorize_url "https://linear.app/oauth/authorize"
  @default_token_url "https://api.linear.app/oauth/token"
  @default_graphql_url "https://api.linear.app/graphql"
  @default_scope "read,write,issues:create,comments:create"

  def config do
    Application.get_env(:rail, :linear_oauth, [])
  end

  def authorize_url(opts \\ []) do
    cfg = config()
    client_id = Keyword.get(opts, :client_id, cfg[:client_id])
    redirect_uri = Keyword.get(opts, :redirect_uri, cfg[:redirect_uri])
    state = Keyword.get(opts, :state)
    scope = Keyword.get(opts, :scope, @default_scope)

    base_params = [
      {"response_type", "code"},
      {"client_id", client_id},
      {"redirect_uri", redirect_uri},
      {"actor", "user"},
      {"scope", scope}
    ]

    params =
      if state do
        [{"state", state} | base_params]
      else
        base_params
      end

    @default_authorize_url <> "?" <> URI.encode_query(params)
  end

  def exchange_code(code, opts \\ []) do
    cfg = config()
    client_id = Keyword.get(opts, :client_id, cfg[:client_id])
    client_secret = Keyword.get(opts, :client_secret, cfg[:client_secret])
    redirect_uri = Keyword.get(opts, :redirect_uri, cfg[:redirect_uri])

    form = [
      grant_type: "authorization_code",
      code: code,
      client_id: client_id,
      client_secret: client_secret,
      redirect_uri: redirect_uri
    ]

    req = build_req(opts)

    case Req.post(req, url: @default_token_url, form: form) do
      {:ok, %{status: 200, body: %{"access_token" => access_token} = body}} ->
        expires_in = body["expires_in"]
        expires_at = if expires_in, do: DateTime.shift(DateTime.utc_now(), second: expires_in)

        {:ok,
         %{
           access_token: access_token,
           refresh_token: body["refresh_token"],
           expires_in: expires_in,
           expires_at: expires_at,
           scope: body["scope"]
         }}

      {:ok, %{status: status, body: body}} ->
        {:error, {:linear_oauth_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def refresh_token(refresh_token, opts \\ []) do
    cfg = config()
    client_id = Keyword.get(opts, :client_id, cfg[:client_id])
    client_secret = Keyword.get(opts, :client_secret, cfg[:client_secret])

    form = [
      grant_type: "refresh_token",
      refresh_token: refresh_token,
      client_id: client_id,
      client_secret: client_secret
    ]

    req = build_req(opts)

    case Req.post(req, url: @default_token_url, form: form) do
      {:ok, %{status: 200, body: %{"access_token" => access_token} = body}} ->
        expires_in = body["expires_in"]
        expires_at = if expires_in, do: DateTime.shift(DateTime.utc_now(), second: expires_in)

        {:ok,
         %{
           access_token: access_token,
           refresh_token: body["refresh_token"],
           expires_in: expires_in,
           expires_at: expires_at
         }}

      {:ok, %{status: status, body: body}} ->
        {:error, {:linear_token_refresh_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def viewer(access_token, opts \\ []) do
    req = build_req(opts)

    query = "query { viewer { id name } }"

    case Req.post(req,
           url: @default_graphql_url,
           auth: {:bearer, access_token},
           json: %{query: query}
         ) do
      {:ok, %{status: 200, body: %{"data" => %{"viewer" => %{"id" => id} = viewer}}}} ->
        {:ok, %{id: id, name: viewer["name"]}}

      {:ok, %{status: status, body: body}} ->
        {:error, {:linear_api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_req(opts) do
    cfg = config()
    req_options = Keyword.get(cfg, :req_options, [])
    custom_opts = Keyword.get(opts, :req_options, [])

    Req.new()
    |> Req.merge(req_options)
    |> Req.merge(custom_opts)
  end
end
