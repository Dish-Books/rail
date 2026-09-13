defmodule Rail.Pipeline.Actions.SetDiffFileViewed do
  @moduledoc false

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc """
  Sets or removes the viewed status and digest for a file diff on a task.
  When `viewed` is truthy, sets `task.viewed_diff_files[file_path] = file_digest`.
  When falsy, removes `file_path` from `task.viewed_diff_files`.
  """
  def set_diff_file_viewed(%Task{} = task, file_path, file_digest, viewed) do
    do_set_viewed(task, file_path, file_digest, viewed)
  end

  def set_diff_file_viewed_unused(%Task{} = task, file_path, file_digest, viewed) do
    do_set_viewed(task, file_path, file_digest, viewed)
  end

  defp do_set_viewed(%Task{} = task, file_path, file_digest, viewed)
       when is_binary(file_path) and is_binary(file_digest) do
    current_viewed = task.viewed_diff_files || %{}

    new_viewed =
      if viewed do
        Map.put(current_viewed, file_path, file_digest)
      else
        Map.delete(current_viewed, file_path)
      end

    {:ok, updated_task} =
      task
      |> Task.changeset(%{viewed_diff_files: new_viewed})
      |> Repo.update()

    {:ok, updated_task}
  end
end
