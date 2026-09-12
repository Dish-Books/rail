defmodule Rail.Pipeline.Actions.ReconcileViewedDiffFiles do
  @moduledoc false

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc """
  Reconciles `task.viewed_diff_files` against `parsed_files`.
  Drops any viewed entry whose path no longer exists or whose digest changed.
  Persists and broadcasts pipeline changes only if the viewed map changed.
  """
  def reconcile_viewed_diff_files(%Task{} = task, parsed_files) when is_list(parsed_files) do
    existing_viewed = task.viewed_diff_files || %{}

    valid_file_map =
      Map.new(parsed_files, fn file ->
        {file.path, file.digest}
      end)

    reconciled =
      Map.filter(existing_viewed, fn {path, digest} ->
        Map.get(valid_file_map, path) == digest
      end)

    if reconciled == existing_viewed do
      {:ok, task}
    else
      {:ok, updated_task} =
        task
        |> Task.changeset(%{viewed_diff_files: reconciled})
        |> Repo.update()


      {:ok, updated_task}
    end
  end
end
