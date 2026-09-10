defmodule RailWeb.AuthController do
  use RailWeb, :controller

  alias Rail.Users
  alias RailWeb.UserAuth

  plug Ueberauth

  def request(conn, _params) do
    conn
  end

  def callback(%{assigns: %{ueberauth_failure: _failure}} = conn, _params) do
    conn
    |> put_flash(:error, "Failed to authenticate with GitHub.")
    |> redirect(to: ~p"/")
  end

  def callback(%{assigns: %{ueberauth_auth: auth}} = conn, _params) do
    case Users.register_oauth_user(auth) do
      {:ok, user} ->
        UserAuth.log_in_user(conn, user)

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Could not sign in with GitHub.")
        |> redirect(to: ~p"/")
    end
  end

  def callback(conn, _params) do
    conn
    |> put_flash(:error, "Authentication was cancelled or failed.")
    |> redirect(to: ~p"/")
  end

  def delete(conn, _params) do
    UserAuth.log_out_user(conn)
  end
end
