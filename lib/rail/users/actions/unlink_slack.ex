defmodule Rail.Users.Actions.UnlinkSlack do
  @moduledoc false

  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Users.Schemas.User

  @doc """
  Forgets the scope's user's Slack account and token.
  """
  def unlink_slack(%Scope{user: %User{} = user}) do
    user
    |> User.changeset(%{slack_user_id: nil, slack_team_id: nil, slack_name: nil, slack_access_token: nil})
    |> Repo.update()
  end

  def unlink_slack(_scope), do: {:error, :not_authenticated}
end
