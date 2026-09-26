defmodule Rail.Triage.Utils.PostToSlack do
  @moduledoc false

  alias Rail.Projects.Schemas.SlackChannel
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Slack
  alias Rail.Triage.Schemas.Message
  alias Rail.Triage.Schemas.Thread
  alias Rail.Users
  alias Rail.Users.Schemas.User

  @doc """
  Posts `text` in `thread` on the scope's user's own Slack token, never the
  bot's, and records the message as theirs so Slack's echo of it is not
  triaged. Needs the thread's channel and workspace preloaded.
  """
  def post_to_slack(%Scope{} = scope, %Thread{slack_channel: %SlackChannel{} = channel} = thread, text) do
    with {:ok, token, team_id} <- linked(scope),
         :ok <- same_workspace(team_id, channel),
         {:ok, %{"ts" => ts}} <- Slack.post_message(token, channel.external_id, thread.external_id, text) do
      {:ok, user} = Users.get_user(id: scope.user.id)
      {:ok, record(thread, user, ts, text)}
    end
  end

  defp linked(scope) do
    case Users.slack_token(scope) do
      {:ok, token, team_id} -> {:ok, token, team_id}
      {:error, :not_linked} -> {:error, :slack_not_linked}
    end
  end

  defp same_workspace(team_id, %SlackChannel{slack_workspace: %{external_id: team_id}}), do: :ok
  defp same_workspace(_team_id, _channel), do: {:error, :slack_other_workspace}

  # Slack's echo can land first, so the row may exist already; it becomes theirs either way.
  defp record(thread, %User{} = user, ts, text) do
    thread
    |> Message.changeset(%{
      external_id: ts,
      author_external_id: user.slack_user_id,
      author_name: user.slack_name || user.name || user.login,
      text: String.replace(text, ~r/<[^|>]+\|([^>]+)>/, "\\1"),
      posted_at: DateTime.utc_now()
    })
    |> Ecto.Changeset.put_change(:sent_by_user_id, user.id)
    |> Repo.insert!(
      on_conflict: {:replace, [:sent_by_user_id, :author_external_id, :author_name, :text, :updated_at]},
      conflict_target: [:thread_id, :external_id]
    )
  end
end
