defmodule Rail.Users.Actions.SetSlackNotifications do
  @moduledoc false

  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Slack
  alias Rail.Users.Schemas.User

  @first_message "Rail will message you here when a task you own waits on you, and when someone else merges it."

  @doc """
  Turns the scope's user's Slack notifications on or off, read fresh because a page's scope can predate a link
  or an unlink. Turning them on first sends a direct message, and Slack's error comes back if it is refused.
  """
  def set_slack_notifications(%Scope{user: %User{id: user_id}}, on?) do
    user = Repo.get!(User, user_id)
    changeset = User.slack_notifications_changeset(user, %{slack_notifications: on?})

    with :ok <- send_first_message(user, changeset),
         {:ok, saved} <- Repo.update(changeset) do
      Phoenix.PubSub.broadcast(Rail.PubSub, "users", {:users_changed, saved.id})
      {:ok, saved}
    end
  end

  def set_slack_notifications(_scope, _on?), do: {:error, :not_authenticated}

  # Sent the way `NotifyOwner` sends, so a first message that arrives proves the path every later one takes.
  defp send_first_message(%User{slack_notifications: false} = user, %Ecto.Changeset{
         valid?: true,
         changes: %{slack_notifications: true}
       }) do
    with "" <> team_id <- user.slack_team_id || {:error, :not_found},
         {:ok, workspace} <- Projects.get_slack_workspace(external_id: team_id),
         {:ok, _ts} <- Slack.post_channel_message(workspace, user.slack_user_id, @first_message) do
      :ok
    end
  end

  defp send_first_message(_user, _changeset), do: :ok
end
