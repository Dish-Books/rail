defmodule Rail.Triage.Actions.BackfillSlackWorkspace do
  @moduledoc """
  Reads what was posted in a workspace's connected channels since Rail last heard from each, and
  files whatever it does not have the way a live event would, so a gap in delivery closes itself.
  """

  import Ecto.Query

  alias Rail.Projects
  alias Rail.Projects.Schemas.SlackChannel
  alias Rail.Projects.Schemas.SlackWorkspace
  alias Rail.Repo
  alias Rail.Slack
  alias Rail.Triage
  alias Rail.Triage.Schemas.Message
  alias Rail.Triage.Schemas.Thread

  require Logger

  @lookback_days 7

  @doc """
  Returns the ts of every message it filed. Nothing older than #{@lookback_days} days, or than the
  channel's connection to its project, is read, so none of it is triaged either.
  """
  def backfill_slack_workspace(%SlackWorkspace{} = workspace) do
    channels = Projects.list_slack_channels(workspace)
    bound = DateTime.shift(DateTime.utc_now(), day: -@lookback_days)

    # Slack's history lists thread parents, not replies, so the newest parent is how far it has been read.
    newest =
      Map.new(
        Repo.all(
          from t in Thread,
            where: t.slack_channel_id in ^Enum.map(channels, & &1.id),
            group_by: t.slack_channel_id,
            select: {t.slack_channel_id, max(t.external_id)}
        )
      )

    Enum.flat_map(channels, fn %SlackChannel{} = channel ->
      floor = "#{[bound, channel.inserted_at] |> Enum.max(DateTime) |> DateTime.to_unix()}.000000"
      # Every ts is ten digits and six more, so they order as strings.
      backfill(workspace, channel, max(floor, Map.get(newest, channel.id, floor)))
    end)
  end

  defp backfill(workspace, channel, oldest) do
    case Slack.history(workspace, channel.external_id, oldest) do
      {:ok, messages} ->
        posted = for %{"ts" => ts} <- messages, do: ts

        filed =
          Repo.all(
            from m in Message,
              join: t in assoc(m, :thread),
              where: t.slack_channel_id == ^channel.id and m.external_id in ^posted,
              select: m.external_id
          )

        # A message already filed is not handed on: a second delivery would reopen and triage its thread again.
        for %{"ts" => ts} = message <- Enum.sort_by(messages, & &1["ts"]),
            ts not in filed,
            event = Map.put(message, "channel", channel.external_id),
            match?({:ok, _thread}, Triage.handle_slack_event(workspace, %{"event" => event})),
            do: ts

      {:error, reason} ->
        Logger.warning("[slack] could not read the history of #{channel.name}: #{inspect(reason)}")
        []
    end
  end
end
