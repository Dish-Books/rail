defmodule RailWeb.AuthController do
  use RailWeb, :controller

  alias Rail.Users
  alias RailWeb.UserAuth

  plug Ueberauth when action in [:request, :callback]

  def request(conn, _params) do
    conn
  end

  def callback(%{assigns: %{ueberauth_failure: _failure}} = conn, _params) do
    deny(conn, "Failed to authenticate with GitHub.")
  end

  def callback(%{assigns: %{ueberauth_auth: auth}} = conn, _params) do
    case Users.sign_in_oauth_user(auth) do
      {:ok, user} ->
        UserAuth.log_in_user(conn, user)

      {:error, :not_invited} ->
        deny(conn, "That GitHub account has not been invited to Rail. Ask an admin for an invite.")

      {:error, :no_email} ->
        deny(conn, "GitHub did not share an email address, so we could not match you to an invite.")

      {:error, _reason} ->
        deny(conn, "Could not sign in with GitHub.")
    end
  end

  def callback(conn, _params) do
    deny(conn, "Authentication was cancelled or failed.")
  end

  def denied(conn, _params) do
    render(conn, :denied)
  end

  def delete(conn, _params) do
    UserAuth.log_out_user(conn)
  end

  # Every authenticated route bounces an anonymous visitor back to /auth/github, so a
  # rejected sign-in cannot be sent home: GitHub would re-authorize silently and the
  # two would trade redirects forever. /auth/denied is the one page that stays put.
  defp deny(conn, message) do
    conn
    |> put_flash(:error, message)
    |> redirect(to: ~p"/auth/denied")
  end
end
