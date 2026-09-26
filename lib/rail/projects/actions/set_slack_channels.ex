defmodule Rail.Projects.Actions.SetSlackChannels do
  @moduledoc false

  import Ecto.Query

  alias Rail.Projects.Schemas.Project
  alias Rail.Projects.Schemas.SlackChannel
  alias Rail.Projects.Schemas.SlackWorkspace
  alias Rail.Repo
  alias Rail.Slack

  @doc """
  Replaces the channels `project` triages. Each entry names a channel by its
  Slack id; its name and workspace come from Slack rather than the form.
  """
  def set_slack_channels(_scope, %Project{id: project_id} = project, channels) when is_list(channels) do
    with {:ok, known} <- known_channels() do
      Repo.transaction(fn ->
        Repo.delete_all(from c in SlackChannel, where: c.project_id == ^project_id)
        Enum.map(channels, &insert(project, known, &1))
      end)
    end
  end

  defp known_channels do
    Enum.reduce_while(Repo.all(SlackWorkspace), {:ok, %{}}, fn workspace, {:ok, acc} ->
      case Slack.list_channels(workspace) do
        {:ok, channels} -> {:cont, {:ok, Enum.into(channels, acc, &{&1["id"], {workspace, &1["name"]}})}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp insert(project, known, %{} = entry) do
    external_id = entry["external_id"] || entry[:external_id]

    case Map.fetch(known, external_id) do
      {:ok, {workspace, name}} ->
        attrs = %{
          external_id: external_id,
          name: name,
          triage_bot_messages: entry["triage_bot_messages"] || entry[:triage_bot_messages] || false
        }

        case project |> SlackChannel.changeset(workspace, attrs) |> Repo.insert() do
          {:ok, channel} -> channel
          {:error, changeset} -> Repo.rollback(changeset)
        end

      :error ->
        Repo.rollback(:channel_not_found)
    end
  end
end
