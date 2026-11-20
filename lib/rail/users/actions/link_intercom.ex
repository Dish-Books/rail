defmodule Rail.Users.Actions.LinkIntercom do
  @moduledoc """
  Connects the scope's user to their Intercom teammate account, so what they send from Support is posted as them.
  """

  alias Rail.Intercom
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Support.Schemas.IntercomWorkspace
  alias Rail.Users.Schemas.User

  @doc """
  Trades the OAuth `code` for the person's token and stores who Intercom says they are, refusing an
  unverified email or an account in another app than the workspace's.
  """
  def link_intercom(%Scope{user: %User{} = user}, %IntercomWorkspace{external_id: app_id} = workspace, code)
      when is_binary(code) do
    with {:ok, %{"access_token" => token}} when is_binary(token) <- Intercom.exchange_code(workspace, code),
         {:ok, %{"id" => admin_id, "email_verified" => true, "app" => %{"id_code" => ^app_id}} = admin} <-
           Intercom.me(token),
         {:ok, user} <-
           user
           |> User.changeset(%{
             intercom_admin_id: to_string(admin_id),
             intercom_app_id: app_id,
             intercom_name: admin["name"],
             intercom_access_token: token
           })
           |> Repo.update() do
      Phoenix.PubSub.broadcast(Rail.PubSub, "users", {:users_changed, user.id})
      {:ok, user}
    else
      {:ok, _unaccepted} -> {:error, :intercom_account_not_accepted}
      {:error, _reason} = error -> error
    end
  end

  def link_intercom(_scope, _workspace, _code), do: {:error, :not_authenticated}
end
