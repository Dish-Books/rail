defmodule Rail.Git.Actions.SaveEnvFile do
  @moduledoc false

  import Ecto.Query
  import Rail.Git.Utils.WithCloneLock
  import Rail.Git.Utils.WriteEnvBlock

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo

  @doc """
  Writes `content` as `project`'s `.env` in its clone, then into every set-up worktree of its tasks.

  Returns `{:ok, %{written: count, refused: [{worktree_path, message}]}}`, or `{:error, reason}` when the
  clone's file could not be written, in which case no worktree is touched.
  """
  # Worktrees are added and removed under the same lock, so none is missed or written into as it goes.
  def save_env_file(%Project{id: project_id, clone_path: clone} = project, content) when is_binary(content) do
    with_clone_lock(clone, fn ->
      with :ok <- File.write(Path.join(clone, ".env"), content) do
        # A setup script takes an existing .env to mean a rerun, so a worktree waiting on one gets nothing yet.
        no_script? = project.worktree_setup_script in [nil, ""]

        paths =
          from(t in Task,
            where: t.project_id == ^project_id and is_nil(t.cleaned_up_at),
            where: ^no_script? or not is_nil(t.worktree_setup_at),
            select: t.worktree_path
          )
          |> Repo.all()
          |> Enum.filter(&File.dir?/1)

        # One worktree that cannot be written stops none of the others.
        results = for path <- paths, do: {path, write_env_block(project, path)}
        refused = for {path, {:error, message}} <- results, do: {path, message}
        {:ok, %{written: length(results) - length(refused), refused: refused}}
      end
    end)
  end
end
