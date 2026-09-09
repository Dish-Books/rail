defmodule RailWeb.UserAuth do
  @moduledoc false

  use RailWeb, :verified_routes

  import Phoenix.Controller
  import Plug.Conn

  alias Rail.Scope
  alias Rail.Users
  alias Rail.Users.Schemas.User

  @max_cookie_age_in_days 14
  @remember_me_cookie "_rail_web_user_remember_me"
  @remember_me_options [
    sign: true,
    max_age: @max_cookie_age_in_days * 24 * 60 * 60,
    same_site: "Lax"
  ]

  @session_reissue_age_in_days 7

  def init(opts), do: opts

  def call(conn, _opts) do
    fetch_current_user(conn, [])
  end

  def log_in_user(conn, user, params \\ %{}) do
    user_return_to = get_session(conn, :user_return_to)

    conn
    |> create_or_extend_session(user, params)
    |> redirect(to: user_return_to || signed_in_path(conn))
  end

  def signed_in_path(_conn), do: ~p"/"

  def log_out_user(conn) do
    user_token = get_session(conn, :user_token)
    user_token && Users.delete_user_session_token(user_token)

    if live_socket_id = get_session(conn, :live_socket_id) do
      RailWeb.Endpoint.broadcast(live_socket_id, "disconnect", %{})
    end

    conn
    |> renew_session(nil)
    |> delete_resp_cookie(@remember_me_cookie)
    |> redirect(to: ~p"/")
  end

  def fetch_current_user(conn, _opts) do
    with {token, conn} <- ensure_user_token(conn),
         {user, token_inserted_at} <- Users.get_user_by_session_token(token) do
      scope = Scope.for_user(user)

      conn
      |> assign(:current_scope, scope)
      |> maybe_reissue_user_session_token(user, token_inserted_at)
    else
      _nil_or_invalid ->
        assign(conn, :current_scope, Scope.for_user(nil))
    end
  end

  def require_authenticated_user(conn, _opts) do
    if conn.assigns[:current_scope] && conn.assigns.current_scope.user do
      conn
    else
      conn
      |> maybe_store_return_to()
      |> redirect(to: ~p"/auth/github")
      |> halt()
    end
  end

  def require_admin_user(conn, _opts) do
    if conn.assigns[:current_scope] && Scope.admin?(conn.assigns.current_scope) do
      conn
    else
      conn
      |> maybe_store_return_to()
      |> redirect(to: ~p"/")
      |> halt()
    end
  end

  def disconnect_sessions(tokens) do
    Enum.each(tokens, fn %{token: token} ->
      RailWeb.Endpoint.broadcast(user_session_topic(token), "disconnect", %{})
    end)
  end

  def on_mount(:mount_current_scope, _params, session, socket) do
    {:cont, mount_current_scope(socket, session)}
  end

  def on_mount(:require_authenticated, _params, session, socket) do
    socket = mount_current_scope(socket, session)

    if socket.assigns[:current_scope] && socket.assigns.current_scope.user do
      {:cont, socket}
    else
      {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/auth/github")}
    end
  end

  def on_mount(:require_admin, _params, session, socket) do
    socket = mount_current_scope(socket, session)

    if socket.assigns[:current_scope] && Scope.admin?(socket.assigns.current_scope) do
      {:cont, socket}
    else
      {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/")}
    end
  end

  defp ensure_user_token(conn) do
    if token = get_session(conn, :user_token) do
      {token, conn}
    else
      conn = fetch_cookies(conn, signed: [@remember_me_cookie])
      token = conn.cookies[@remember_me_cookie]

      if token do
        {token, conn |> put_token_in_session(token) |> put_session(:user_remember_me, true)}
      end
    end
  end

  defp maybe_reissue_user_session_token(conn, user, token_inserted_at) do
    token_age = DateTime.diff(DateTime.utc_now(), token_inserted_at, :day)

    if token_age >= @session_reissue_age_in_days do
      create_or_extend_session(conn, user, %{})
    else
      conn
    end
  end

  defp create_or_extend_session(conn, user, params) do
    token = Users.generate_user_session_token(user)
    remember_me = get_session(conn, :user_remember_me)

    conn
    |> renew_session(user)
    |> put_token_in_session(token)
    |> maybe_write_remember_me_cookie(token, params, remember_me)
  end

  defp renew_session(conn, %User{} = user)
       when is_map_key(conn.assigns, :current_scope) and is_map(conn.assigns.current_scope) and
              is_map(conn.assigns.current_scope.user) and conn.assigns.current_scope.user.id == user.id do
    conn
  end

  defp renew_session(conn, _user) do
    delete_csrf_token()

    conn
    |> configure_session(renew: true)
    |> clear_session()
  end

  defp maybe_write_remember_me_cookie(conn, token, %{"remember_me" => "true"}, _value) do
    write_remember_me_cookie(conn, token)
  end

  defp maybe_write_remember_me_cookie(conn, token, _params, true) do
    write_remember_me_cookie(conn, token)
  end

  defp maybe_write_remember_me_cookie(conn, _token, _params, _value) do
    conn
  end

  defp write_remember_me_cookie(conn, token) do
    conn
    |> put_session(:user_remember_me, true)
    |> put_resp_cookie(@remember_me_cookie, token, @remember_me_options)
  end

  defp put_token_in_session(conn, token) do
    conn
    |> put_session(:user_token, token)
    |> put_session(:live_socket_id, user_session_topic(token))
  end

  defp user_session_topic(token), do: "users_sessions:#{Base.url_encode64(token)}"

  defp mount_current_scope(socket, session) do
    Phoenix.Component.assign_new(socket, :current_scope, fn ->
      {user, _token_inserted_at} =
        if user_token = session["user_token"] do
          Users.get_user_by_session_token(user_token)
        end || {nil, nil}

      Scope.for_user(user)
    end)
  end

  defp maybe_store_return_to(%{method: "GET"} = conn) do
    put_session(conn, :user_return_to, current_path(conn))
  end

  defp maybe_store_return_to(conn), do: conn
end
