defmodule Rail.Support.Utils.VerifyIntercomSender do
  @moduledoc false

  alias Rail.Scope
  alias Rail.Support.Schemas.IntercomWorkspace
  alias Rail.Users.Schemas.User

  @doc """
  Whether the person can post in the workspace's Intercom as themselves: linked, and to that app.
  Returns `:ok`, `{:error, :intercom_not_linked}` or `{:error, :intercom_other_workspace}`.
  """
  def verify_intercom_sender(%User{} = user, %IntercomWorkspace{external_id: app_id}) do
    cond do
      not Scope.intercom_linked?(Scope.for_user(user)) -> {:error, :intercom_not_linked}
      user.intercom_app_id != app_id -> {:error, :intercom_other_workspace}
      true -> :ok
    end
  end
end
