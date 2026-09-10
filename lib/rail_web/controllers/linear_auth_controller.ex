defmodule RailWeb.LinearAuthController do
  use RailWeb, :controller

  alias Rail.Linear
  alias Rail.Users

  def request(conn, _params) do
    state = 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    authorize_url = Linear.authorize_url(state: state)

    conn
    |> put_session(:linear_oauth_state, state)
    |> redirect(external: authorize_url)
  end

  def callback(conn, %{"code" => code}) do
    case Linear.exchange_code(code) do
      {:ok, tokens} ->
        handle_token_exchange(conn, tokens)

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Failed to exchange Linear authorization code.")
        |> redirect(to: ~p"/settings/connected-accounts")
    end
  end

  def callback(conn, %{"error" => _error}) do
    conn
    |> put_flash(:error, "Linear authentication was denied or cancelled.")
    |> redirect(to: ~p"/settings/connected-accounts")
  end

  def callback(conn, _params) do
    conn
    |> put_flash(:error, "Linear authentication failed.")
    |> redirect(to: ~p"/settings/connected-accounts")
  end

  def unlink(conn, _params) do
    case Users.unlink_linear(conn.assigns[:current_scope]) do
      {:ok, _user} ->
        conn
        |> put_flash(:info, "Disconnected Linear account.")
        |> redirect(to: ~p"/settings/connected-accounts")

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Could not disconnect Linear account.")
        |> redirect(to: ~p"/settings/connected-accounts")
    end
  end

  defp handle_token_exchange(conn, tokens) do
    case Linear.viewer(tokens.access_token) do
      {:ok, viewer} ->
        link_user(conn, tokens, viewer)

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Failed to fetch Linear user profile.")
        |> redirect(to: ~p"/settings/connected-accounts")
    end
  end

  defp link_user(conn, tokens, viewer) do
    attrs = %{
      linear_user_id: viewer.id,
      linear_name: viewer.name,
      linear_access_token: tokens.access_token,
      linear_refresh_token: tokens.refresh_token,
      linear_token_expires_at: tokens.expires_at
    }

    case Users.link_linear(conn.assigns[:current_scope], attrs) do
      {:ok, _user} ->
        conn
        |> delete_session(:linear_oauth_state)
        |> put_flash(:info, "Connected Linear account successfully.")
        |> redirect(to: ~p"/settings/connected-accounts")

      {:error, _changeset} ->
        conn
        |> put_flash(:error, "Failed to link Linear account.")
        |> redirect(to: ~p"/settings/connected-accounts")
    end
  end
end
