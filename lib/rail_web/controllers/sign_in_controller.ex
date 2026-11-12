defmodule RailWeb.SignInController do
  use RailWeb, :controller

  alias Rail.Scope
  alias Rail.Users
  alias RailWeb.UserAuth

  def index(conn, _params) do
    assertion = Rail.cloudflare_access() && conn |> get_req_header("cf-access-jwt-assertion") |> List.first()

    cond do
      Scope.admin?(conn.assigns[:current_scope]) or signed_in?(conn) -> redirect(conn, to: ~p"/")
      is_binary(assertion) -> sign_in_access_user(conn, assertion)
      true -> render(conn, :index, page_title: "Sign in")
    end
  end

  defp sign_in_access_user(conn, assertion) do
    case Users.sign_in_access_user(assertion) do
      {:ok, user} -> UserAuth.log_in_user(conn, user)
      {:error, {:not_invited, email}} -> deny(conn, "#{email} has not been invited to Rail.")
      {:error, :invalid_assertion} -> deny(conn, "Cloudflare Access could not vouch for who you are.")
      {:error, _reason} -> deny(conn, "Could not sign in through Cloudflare Access.")
    end
  end

  # The denied page stays put, where sending them home would bring them straight back here.
  defp deny(conn, message) do
    conn
    |> put_flash(:error, message)
    |> redirect(to: ~p"/auth/denied")
  end

  defp signed_in?(conn), do: conn.assigns[:current_scope] != nil and conn.assigns.current_scope.user != nil
end
