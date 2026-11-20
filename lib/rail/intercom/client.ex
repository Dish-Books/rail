defmodule Rail.Intercom.Client do
  @moduledoc """
  The one client for Intercom: the REST API a workspace's token reads conversations with,
  a person's token replies with, and the OAuth a person links their account through.
  """

  alias Rail.Support.Schemas.IntercomWorkspace

  @api_url "https://api.intercom.io"
  @authorize_url "https://app.intercom.com/oauth"
  @version "2.11"
  @page_size 150
  # Intercom answers 406 to an API call that doesn't ask for JSON, before it reads the token.
  @api_headers [{"accept", "application/json"}, {"intercom-version", @version}]

  def me(token) when is_binary(token), do: get(token, "/me", [])

  @doc """
  One page of conversations, without their parts, and the cursor for the next page or nil.
  """
  def list_conversations(%IntercomWorkspace{access_token: token}, starting_after) do
    params = Enum.reject([per_page: @page_size, starting_after: starting_after], &is_nil(elem(&1, 1)))

    with {:ok, body} <- get(token, "/conversations", params) do
      {:ok, body["conversations"] || [], get_in(body, ["pages", "next", "starting_after"])}
    end
  end

  def get_conversation(%IntercomWorkspace{access_token: token}, external_id),
    do: get(token, "/conversations/#{external_id}", [])

  @doc """
  Posts `body`, HTML, as a reply from the teammate `admin_id`, with that teammate's own token.
  """
  def reply(token, external_id, admin_id, body) when is_binary(token) and is_binary(admin_id) do
    req()
    |> Req.post(
      url: "#{@api_url}/conversations/#{external_id}/reply",
      auth: {:bearer, token},
      headers: @api_headers,
      json: %{message_type: "comment", type: "admin", admin_id: admin_id, body: body}
    )
    |> answer()
  end

  @doc """
  Downloads an attached file from Intercom's own hosts, with the workspace's token. Any other address is refused.
  """
  def download_file(%IntercomWorkspace{access_token: token}, url) when is_binary(url) do
    uri = URI.parse(url)

    if uri.scheme == "https" and is_binary(uri.host) and
         (uri.host == "api.intercom.io" or String.ends_with?(uri.host, ".intercomcdn.com")) do
      req()
      |> Req.get(url: url, auth: {:bearer, token}, decode_body: false)
      |> answer()
    else
      {:error, :not_an_intercom_file}
    end
  end

  def authorize_url(%IntercomWorkspace{client_id: client_id}, state),
    do: @authorize_url <> "?" <> URI.encode_query(client_id: client_id, state: state, redirect_uri: redirect_uri())

  def exchange_code(%IntercomWorkspace{} = workspace, code) do
    req()
    |> Req.post(
      url: "#{@api_url}/auth/eagle/token",
      headers: [{"accept", "application/json"}],
      form: [code: code, client_id: workspace.client_id, client_secret: workspace.client_secret]
    )
    |> answer()
  end

  defp get(token, path, params) do
    req()
    |> Req.get(url: @api_url <> path, params: params, auth: {:bearer, token}, headers: @api_headers)
    |> answer()
  end

  defp req, do: Req.merge(Req.new(), Keyword.get(Application.get_env(:rail, :intercom, []), :req_options, []))

  defp answer({:ok, %Req.Response{status: status, body: body}}) when status in 200..299, do: {:ok, body}
  defp answer({:ok, %Req.Response{status: status, body: body}}), do: {:error, {:intercom_error, status, body}}
  defp answer({:error, reason}), do: {:error, reason}

  defp redirect_uri, do: RailWeb.Endpoint.url() <> "/auth/intercom/callback"
end
