defmodule RailWeb.UserAuth do
  @moduledoc false

  use RailWeb, :verified_routes

  import Phoenix.Controller
  import Plug.Conn

  alias Rail.Scope
  alias Rail.Users
  alias Rail.Users.Schemas.User

  @session_reissue_age_in_days 7

  def init(opts), do: opts

  def call(conn, :require_authenticated_user) do
    require_authenticated_user(conn, [])
  end

  def call(conn, :require_admin_user) do
    require_admin_user(conn, [])
  end

  def call(conn, _opts) do
    fetch_current_user(conn, [])
  end

  def log_in_user(conn, user) do
    user_return_to = get_session(conn, :user_return_to)

    conn
    |> create_or_extend_session(user)
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
    |> redirect(to: ~p"/")
  end

  def fetch_current_user(conn, _opts) do
    with token when is_binary(token) <- get_session(conn, :user_token),
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

  defp maybe_reissue_user_session_token(conn, user, token_inserted_at) do
    token_age = DateTime.diff(DateTime.utc_now(), token_inserted_at, :day)

    if token_age >= @session_reissue_age_in_days do
      create_or_extend_session(conn, user)
    else
      conn
    end
  end

  defp create_or_extend_session(conn, user) do
    previous_token = get_session(conn, :user_token)
    token = Users.generate_user_session_token(user)

    conn =
      conn
      |> renew_session(user)
      |> put_token_in_session(token)

    # The superseded token would otherwise stay valid for the rest of its 14 days,
    # surviving both rotation and a later logout.
    if previous_token && previous_token != token do
      Users.delete_user_session_token(previous_token)
    end

    conn
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
