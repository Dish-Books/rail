defmodule RailWeb.SignInController do
  use RailWeb, :controller

  alias Rail.Scope

  def index(conn, _params) do
    if Scope.admin?(conn.assigns[:current_scope]) or signed_in?(conn) do
      redirect(conn, to: ~p"/")
    else
      render(conn, :index, page_title: "Sign in")
    end
  end

  defp signed_in?(conn), do: conn.assigns[:current_scope] != nil and conn.assigns.current_scope.user != nil
end
