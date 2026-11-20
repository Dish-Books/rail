defmodule RailWeb.IntercomAuthController do
  use RailWeb, :controller

  alias Rail.Intercom
  alias Rail.Support
  alias Rail.Users

  def request(conn, %{"workspace_id" => workspace_id}) when is_binary(workspace_id) do
    case Support.get_intercom_workspace(id: workspace_id) do
      {:ok, workspace} ->
        state = 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

        conn
        |> put_session(:intercom_oauth_state, state)
        |> put_session(:intercom_oauth_workspace_id, workspace.id)
        |> redirect(external: Intercom.authorize_url(workspace, state))

      {:error, :not_found} ->
        redirect_with(conn, :error, "That Intercom workspace is no longer connected.")
    end
  end

  def request(conn, _params), do: redirect_with(conn, :error, "Pick an Intercom workspace to connect.")

  def callback(conn, %{"code" => code, "state" => state}) do
    expected = get_session(conn, :intercom_oauth_state)
    workspace_id = get_session(conn, :intercom_oauth_workspace_id)
    conn = conn |> delete_session(:intercom_oauth_state) |> delete_session(:intercom_oauth_workspace_id)

    with true <-
           is_binary(expected) and expected != "" and is_binary(state) and Plug.Crypto.secure_compare(expected, state),
         {:ok, workspace} <- Support.get_intercom_workspace(id: to_string(workspace_id)),
         {:ok, _user} <- Users.link_intercom(conn.assigns.current_scope, workspace, code) do
      redirect_with(conn, :info, "Connected Intercom account successfully.")
    else
      false ->
        redirect_with(conn, :error, "Intercom authentication failed. Please try connecting again.")

      {:error, :intercom_account_not_accepted} ->
        redirect_with(conn, :error, "Intercom did not confirm this account for the connected workspace.")

      {:error, _reason} ->
        redirect_with(conn, :error, "Failed to connect Intercom account.")
    end
  end

  def callback(conn, _params), do: redirect_with(conn, :error, "Intercom authentication was denied or cancelled.")

  defp redirect_with(conn, kind, message) do
    conn
    |> put_flash(kind, message)
    |> redirect(to: ~p"/settings/connected-accounts")
  end
end
