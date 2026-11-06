defmodule Rail.Git.Actions.DeleteViewedFiles do
  @moduledoc """
  Forgets every read mark on a task, for Back to Plan, whose diff and plans start over.
  """

  import Ecto.Query

  alias Rail.Git.Schemas.ViewedFile
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc """
  Deletes every person's marks on `task`'s diff, plan and fix plan.
  """
  def delete_viewed_files(%Task{id: task_id}) do
    {_deleted, nil} = Repo.delete_all(from(viewed_file in ViewedFile, where: viewed_file.task_id == ^task_id))
    :ok
  end
end
