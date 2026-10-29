defmodule Rail.Users.Actions.SetSlackNotifications do
  @moduledoc false

  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Users.Schemas.User

  @doc """
  Turns the scope's user's Slack notifications on or off, read fresh because a page's scope can predate a link
  or an unlink. Returns the updated user, or the changeset when they have no Slack account to message.
  """
  def set_slack_notifications(%Scope{user: %User{id: user_id}}, on?) do
    User
    |> Repo.get!(user_id)
    |> User.slack_notifications_changeset(%{slack_notifications: on?})
    |> Repo.update()
  end

  def set_slack_notifications(_scope, _on?), do: {:error, :not_authenticated}
end
