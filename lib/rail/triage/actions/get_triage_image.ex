defmodule Rail.Triage.Actions.GetTriageImage do
  @moduledoc false

  import Ecto.Query

  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Slack
  alias Rail.Triage.Schemas.Message
  alias Rail.Triage.Schemas.Thread

  @doc """
  Fetches an image a message came with from Slack, by its Slack file id. Returns
  `{:ok, mimetype, body}`. A message in a project the scope cannot see is not found.
  """
  def get_triage_image(scope, message_id, file_id) when is_binary(message_id) and is_binary(file_id) do
    query =
      from m in Message,
        join: t in Thread,
        on: t.id == m.thread_id,
        where: m.id == ^message_id,
        preload: [thread: {t, slack_channel: :slack_workspace}]

    query = if ids = Scope.project_ids(scope), do: where(query, [_m, t], t.project_id in ^ids), else: query

    with %Message{} = message <- Repo.one(query),
         # A file Slack withheld has no address, so it never reaches Slack.
         %Message.Image{url: url, mimetype: mimetype} when is_binary(url) <-
           Enum.find(message.images, &(&1.external_id == file_id)),
         {:ok, body} <- Slack.download_file(message.thread.slack_channel.slack_workspace, url) do
      {:ok, mimetype, body}
    else
      {:error, _unreadable} = error -> error
      nil -> {:error, :not_found}
      %Message.Image{} -> {:error, :not_found}
    end
  end
end
