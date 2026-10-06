defmodule Rail.Triage.Actions.GetTriageImage do
  @moduledoc false

  import Ecto.Query

  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Slack
  alias Rail.Triage.Schemas.Message
  alias Rail.Triage.Schemas.Thread

  @doc """
  An image a message came with, by its Slack file id, downloaded from Slack once and
  then kept in the thread's scratch. Returns `{:ok, mimetype, body}`. A message in a
  project the scope cannot see is not found.
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
         {:ok, body} <- fetch(message.thread, file_id, url) do
      {:ok, mimetype, body}
    else
      {:error, _unreadable} = error -> error
      nil -> {:error, :not_found}
      %Message.Image{} -> {:error, :not_found}
    end
  end

  defp fetch(%Thread{} = thread, file_id, url) do
    dir = Path.join(Thread.scratch_path(thread), "image_cache")
    path = Path.join(dir, Base.url_encode64(file_id, padding: false))

    case read_kept(dir, path) do
      {:ok, body} ->
        {:ok, body}

      :missing ->
        with {:ok, body} <- Slack.download_file(thread.slack_channel.slack_workspace, url) do
          keep(dir, path, body)
          {:ok, body}
        end
    end
  end

  # The triage agent can write in the thread's scratch, so only a plain file reached
  # through no link is read, and the file opened must be the one that was checked.
  defp read_kept(dir, path) do
    with {:ok, %File.Stat{type: :directory}} <- File.lstat(dir),
         {:ok, %File.Stat{type: :regular} = checked} <- File.lstat(path),
         {:ok, fd} <- :file.open(path, [:read, :raw, :binary]) do
      try do
        with {:ok, info} <- :file.read_file_info(fd),
             %File.Stat{inode: inode, major_device: device, size: size} when size > 0 <- File.Stat.from_record(info),
             true <- {inode, device} == {checked.inode, checked.major_device},
             {:ok, body} <- :file.read(fd, size) do
          {:ok, body}
        else
          _changed -> :missing
        end
      after
        :file.close(fd)
      end
    else
      _not_kept -> :missing
    end
  end

  # Written aside and renamed into place, so a reader never sees half a file and a
  # link planted where it goes is replaced rather than written through.
  defp keep(dir, path, body) do
    File.mkdir_p(dir)

    with {:ok, %File.Stat{type: :directory}} <- File.lstat(dir) do
      written = "#{path}.#{System.unique_integer([:positive])}"
      :ok = File.write(written, body, [:exclusive])
      with {:error, _occupied} <- File.rename(written, path), do: File.rm(written)
    end
  end
end
