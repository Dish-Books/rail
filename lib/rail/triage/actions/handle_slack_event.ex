defmodule Rail.Triage.Actions.HandleSlackEvent do
  @moduledoc """
  Takes a message Slack delivered and files it under its thread, scheduling a
  pass when it is something triage should read.

  Only people's messages in a project's connected channels trigger one. A bot's
  post triggers only where the channel opted in and never when it is Rail's own,
  and a message a teammate posted through Rail never does. Edits and deletions
  are ignored.
  """

  import Rail.Triage.Utils.EnqueueTriage
  import Rail.Triage.Utils.UpsertSlackMessage

  alias Rail.Projects
  alias Rail.Projects.Schemas.SlackChannel
  alias Rail.Projects.Schemas.SlackWorkspace
  alias Rail.Repo
  alias Rail.Triage.Schemas.Message
  alias Rail.Triage.Schemas.Thread

  @subtypes [nil, "thread_broadcast", "file_share", "bot_message"]
  @delay_seconds 15

  @doc """
  Returns `{:ok, thread}` for a message it filed, or `:ignored`.
  """
  def handle_slack_event(%SlackWorkspace{} = workspace, %{"event" => %{"type" => "message"} = event}) do
    with true <- event["channel_type"] not in ["im", "mpim"] and event["subtype"] in @subtypes,
         {:ok, %SlackChannel{} = channel} <- channel(workspace, event["channel"]) do
      file(workspace, channel, event)
    else
      _not_triaged -> :ignored
    end
  end

  def handle_slack_event(%SlackWorkspace{}, _payload), do: :ignored

  defp channel(%SlackWorkspace{id: workspace_id}, channel_id) when is_binary(channel_id) do
    case Projects.get_slack_channel(external_id: channel_id) do
      {:ok, %SlackChannel{slack_workspace_id: ^workspace_id} = channel} -> {:ok, channel}
      _elsewhere -> :ignored
    end
  end

  defp channel(_workspace, _no_channel), do: :ignored

  defp file(workspace, channel, %{"ts" => ts} = event) do
    now = DateTime.utc_now()

    thread =
      channel
      |> Thread.changeset(%{external_id: event["thread_ts"] || ts, last_message_at: now})
      |> Repo.insert!(
        on_conflict: [set: [last_message_at: now, updated_at: now]],
        conflict_target: [:slack_channel_id, :external_id],
        returning: true
      )

    {:ok, message, _names} = upsert_slack_message(thread, workspace, event, %{})

    if triggers?(workspace, channel, event, message) do
      enqueue_triage(thread, schedule_in: @delay_seconds)
    else
      {:ok, thread}
    end
  end

  defp triggers?(workspace, channel, event, message) do
    cond do
      Message.via_rail?(message) -> false
      is_binary(event["bot_id"]) -> channel.triage_bot_messages and event["bot_id"] != workspace.bot_id
      true -> true
    end
  end
end
