defmodule Rail.Git.Actions.ListViewedFiles do
  @moduledoc """
  The files this reader has marked read on a task's diff.
  """

  import Ecto.Query

  alias Rail.Git.Schemas.ViewedFile
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Returns `%{path => digest}` for the scope's own marks.

  The digest is what the file looked like when it was read, so the caller can
  tell a file still read from one that has moved since.
  """
  def list_viewed_files(%Scope{user: %{id: user_id}}, %Task{id: task_id}) do
    query =
      from viewed_file in ViewedFile,
        where: viewed_file.task_id == ^task_id and viewed_file.user_id == ^user_id,
        select: {viewed_file.path, viewed_file.digest}

    query |> Repo.all() |> Map.new()
  end

  def list_viewed_files(_no_user, %Task{}), do: %{}
end
