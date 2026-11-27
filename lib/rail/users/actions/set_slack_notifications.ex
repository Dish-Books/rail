defmodule Rail.Users.Actions.SetSlackNotifications do
  @moduledoc false

  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Slack
  alias Rail.Users
  alias Rail.Users.Schemas.User

  @fields %{tasks: :slack_notifications, support: :slack_support_notifications}
  @first_messages %{
    tasks: "Rail will message you here when a task you own waits on you, and when someone else merges it.",
    support: "Rail will message you here when a customer writes in Support, in the projects you can see."
  }

  @doc """
  Turns the user's `:tasks` or `:support` Slack notifications on or off, read fresh as a page's scope can predate a link.
  Turning one on first sends a direct message, and Slack's error comes back if it is refused.
  """
  def set_slack_notifications(%Scope{user: %User{id: user_id}}, kind, on?) when is_map_key(@fields, kind) do
    user = Repo.get!(User, user_id)
    field = Map.fetch!(@fields, kind)
    changeset = User.slack_notifications_changeset(user, %{field => on?})

    with :ok <- authorize(user, kind, on?),
         :ok <- send_first_message(user, changeset, field, Map.fetch!(@first_messages, kind)),
         {:ok, saved} <- Repo.update(changeset) do
      Phoenix.PubSub.broadcast(Rail.PubSub, "users", {:users_changed, saved.id})
      {:ok, saved}
    end
  end

  def set_slack_notifications(_scope, _kind, _on?), do: {:error, :not_authenticated}

  defp authorize(%User{} = user, :support, true) do
    if Users.can?(Scope.for_user(user), :support, :view), do: :ok, else: {:error, :not_authorized}
  end

  defp authorize(_user, _kind, _on?), do: :ok

  # Sent the way the notification workers send, so a first message that arrives proves the path every later one takes.
  defp send_first_message(%User{} = user, %Ecto.Changeset{valid?: true, changes: changes}, field, text) do
    with true <- Map.fetch!(user, field) == false and Map.get(changes, field) == true,
         "" <> team_id <- user.slack_team_id || {:error, :not_found},
         {:ok, workspace} <- Projects.get_slack_workspace(external_id: team_id),
         {:ok, _ts} <- Slack.post_channel_message(workspace, user.slack_user_id, text) do
      :ok
    else
      false -> :ok
      error -> error
    end
  end

  defp send_first_message(_user, _changeset, _field, _text), do: :ok
end
