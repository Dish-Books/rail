defmodule RailWeb.LinearAuthController do
  use RailWeb, :controller

  alias Rail.Linear
  alias Rail.Scope
  alias Rail.Users

  def request(conn, _params) do
    state = 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    authorize_url = Linear.authorize_url(state: state)

    conn
    |> put_session(:linear_oauth_state, state)
    |> redirect(external: authorize_url)
  end

  def callback(conn, %{"code" => code, "state" => state}) do
    expected_state = get_session(conn, :linear_oauth_state)
    conn = delete_session(conn, :linear_oauth_state)

    if valid_state?(expected_state, state) do
      exchange_and_link(conn, code)
    else
      conn
      |> put_flash(:error, "Linear authentication failed. Please try connecting again.")
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

  def unlink(conn, %{} = _params) do
    case current_user(conn) do
      nil ->
        conn
        |> put_flash(:error, "Could not disconnect Linear account.")
        |> redirect(to: ~p"/settings/connected-accounts")

      user ->
        do_unlink(conn, user)
    end
  end

  defp do_unlink(conn, user) do
    case Users.update_user(Scope.for_system(), user, %{
           linear_user_id: nil,
           linear_name: nil,
           linear_access_token: nil,
           linear_refresh_token: nil,
           linear_token_expires_at: nil
         }) do
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

  defp current_user(conn) do
    scope = conn.assigns[:current_scope]
    scope && scope.user
  end

  defp exchange_and_link(conn, code) do
    case Linear.exchange_code(code) do
      {:ok, tokens} ->
        handle_token_exchange(conn, tokens)

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Failed to exchange Linear authorization code.")
        |> redirect(to: ~p"/settings/connected-accounts")
    end
  end

  defp valid_state?(expected, given) when is_binary(expected) and is_binary(given) and expected != "" do
    Plug.Crypto.secure_compare(expected, given)
  end

  defp valid_state?(_expected, _given), do: false

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

    case Users.update_user(Scope.for_system(), current_user(conn), attrs) do
      {:ok, _user} ->
        conn
        |> put_flash(:info, "Connected Linear account successfully.")
        |> redirect(to: ~p"/settings/connected-accounts")

      {:error, _changeset} ->
        conn
        |> put_flash(:error, "Failed to link Linear account.")
        |> redirect(to: ~p"/settings/connected-accounts")
    end
  end
end
