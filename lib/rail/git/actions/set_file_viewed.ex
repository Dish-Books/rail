defmodule Rail.Git.Actions.SetFileViewed do
  @moduledoc """
  Marks one file of a task's diff read, or unread, for one person.

  The digest is stored alongside, so the mark stands only for the file as it was
  read. A file the engineer touches again has a different digest and reads
  unviewed by itself, which is why nothing has to go back and reconcile these
  rows when the diff moves.
  """

  alias Rail.Git.Schemas.ViewedFile
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Sets whether `path` is read by the scope's user.
  """
  def set_file_viewed(%Scope{user: %{id: user_id}}, %Task{id: task_id}, path, digest, true) do
    attrs = %{
      task_id: task_id,
      user_id: user_id,
      path: path,
      digest: digest,
      viewed_at: DateTime.utc_now()
    }

    %ViewedFile{}
    |> ViewedFile.changeset(attrs)
    |> Repo.insert(
      on_conflict: [set: [digest: digest, viewed_at: attrs.viewed_at, updated_at: DateTime.utc_now()]],
      conflict_target: [:task_id, :user_id, :path]
    )
  end

  def set_file_viewed(%Scope{user: %{id: user_id}}, %Task{id: task_id}, path, _digest, false) do
    case Repo.get_by(ViewedFile, task_id: task_id, user_id: user_id, path: path) do
      %ViewedFile{} = viewed_file -> Repo.delete(viewed_file)
      nil -> {:ok, nil}
    end
  end
end
