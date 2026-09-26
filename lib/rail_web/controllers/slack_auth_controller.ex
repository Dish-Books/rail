defmodule RailWeb.SlackAuthController do
  use RailWeb, :controller

  alias Rail.Slack
  alias Rail.Users

  def request(conn, _params) do
    state = 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

    conn
    |> put_session(:slack_oauth_state, state)
    |> redirect(external: Slack.authorize_url(state: state))
  end

  def callback(conn, %{"code" => code, "state" => state}) do
    expected_state = get_session(conn, :slack_oauth_state)
    conn = delete_session(conn, :slack_oauth_state)

    if is_binary(expected_state) and expected_state != "" and is_binary(state) and
         Plug.Crypto.secure_compare(expected_state, state) do
      case Users.link_slack(conn.assigns.current_scope, code) do
        {:ok, _user} -> redirect_with(conn, :info, "Connected Slack account successfully.")
        {:error, _reason} -> redirect_with(conn, :error, "Failed to connect Slack account.")
      end
    else
      redirect_with(conn, :error, "Slack authentication failed. Please try connecting again.")
    end
  end

  def callback(conn, %{"error" => _error}) do
    redirect_with(conn, :error, "Slack authentication was denied or cancelled.")
  end

  def callback(conn, _params) do
    redirect_with(conn, :error, "Slack authentication failed.")
  end

  defp redirect_with(conn, kind, message) do
    conn
    |> put_flash(kind, message)
    |> redirect(to: ~p"/settings/connected-accounts")
  end
end
