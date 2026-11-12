defmodule RailWeb.AuthController do
  use RailWeb, :controller

  alias Rail.Scope
  alias Rail.Users
  alias Rail.Users.Schemas.User
  alias RailWeb.UserAuth

  plug Ueberauth when action in [:request, :callback]

  def request(conn, _params) do
    conn
  end

  # Someone already signed in is connecting GitHub from Connected accounts, not signing in.
  def callback(%{assigns: %{current_scope: %Scope{user: %User{}} = scope}} = conn, _params) do
    case conn.assigns do
      %{ueberauth_auth: auth} -> link_github(conn, scope, auth)
      _failed_or_cancelled -> github_error(conn, "GitHub did not finish connecting. Nothing changed.")
    end
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

  def denied(conn, params) do
    access? = Rail.cloudflare_access() != nil
    show_unreachable = access? and params["reason"] == "unreachable"

    render(conn, :denied,
      access?: access?,
      show_unreachable: show_unreachable,
      show_access_help: access? and not show_unreachable
    )
  end

  def delete(conn, _params) do
    UserAuth.log_out_user(conn)
  end

  defp link_github(conn, %Scope{} = scope, auth) do
    case Users.link_github(scope, auth) do
      {:ok, _user} ->
        redirect(conn, to: ~p"/settings/connected-accounts")

      {:error, {:github_taken, %User{} = holder}} ->
        github_error(
          conn,
          "That GitHub account, #{holder.login}, is already connected to #{holder.name || holder.email}'s Rail account. Nothing changed."
        )

      {:error, {:github_already_linked, %User{} = user}} ->
        github_error(
          conn,
          "Your Rail account is connected to GitHub as #{user.login}. Disconnect it to connect another. Nothing changed."
        )

      {:error, _reason} ->
        github_error(conn, "Could not connect GitHub. Nothing changed.")
    end
  end

  defp github_error(conn, message) do
    conn
    |> put_flash(:github_error, message)
    |> redirect(to: ~p"/settings/connected-accounts")
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
