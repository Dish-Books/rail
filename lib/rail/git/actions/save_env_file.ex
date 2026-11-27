defmodule Rail.Git.Actions.SaveEnvFile do
  @moduledoc false

  import Ecto.Query
  import Rail.Git.Utils.LocalCheckout
  import Rail.Git.Utils.WithCloneLock
  import Rail.Git.Utils.WriteEnvBlock

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo

  @doc """
  Writes `content` as `project`'s `.env` in its clone, then into every set-up checkout of its tasks.

  Returns `{:ok, %{written: count, refused: [{worktree_path, message}]}}`, or `{:error, reason}` when the
  clone's file could not be written, in which case no checkout is touched.
  """
  # Checkouts are made and removed under the same lock, so none is missed or written into as it goes.
  def save_env_file(%Project{id: project_id, clone_path: clone} = project, content) when is_binary(content) do
    with_clone_lock(clone, fn ->
      with :ok <- File.write(Path.join(clone, ".env"), content) do
        # A setup script takes an existing .env to mean a rerun, so a checkout waiting on one gets nothing yet.
        no_script? = project.worktree_setup_script in [nil, ""]

        tasks =
          from(t in Task,
            where: t.project_id == ^project_id and is_nil(t.cleaned_up_at),
            where: ^no_script? or not is_nil(t.worktree_setup_at)
          )
          |> Repo.all()
          |> Enum.filter(&has_checkout?/1)

        # One checkout that cannot be written stops none of the others.
        results = for task <- tasks, do: {task.worktree_path, written(project, task, no_script?)}
        refused = for {path, {:error, message}} <- results, do: {path, message}
        {:ok, %{written: length(results) - length(refused), refused: refused}}
      end
    end)
  end

  defp has_checkout?(%Task{} = task) do
    if Rail.sandbox_runtime() == :local, do: is_binary(local_checkout(task)), else: Task.worktree_present?(task)
  end

  # A stopped sandbox of a project with no script gets the .env with its checkout when it starts again.
  defp written(%Project{} = project, %Task{} = task, no_script?) do
    case write_env_block(project, task) do
      {:error, :not_running} when no_script? -> :ok
      {:error, :not_running} -> {:error, "The task's sandbox is not running, so its .env was not written."}
      written -> written
    end
  end
end
