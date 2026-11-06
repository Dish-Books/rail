defmodule Rail.Projects.Actions.SaveEnvFile do
  @moduledoc false

  alias Rail.Git
  alias Rail.Projects.Schemas.EnvFile
  alias Rail.Projects.Schemas.Project

  @doc """
  Writes the rows in `attrs` as `project`'s `.env`, in its clone and every set-up worktree.

  Returns `{:ok, %{written: count, refused: [{worktree_path, message}]}}`, `{:error, changeset}` with nothing
  written when a row is wrong, or `{:error, reason}` when the clone's file could not be written.
  """
  def save_env_file(_scope, %Project{} = project, attrs) do
    with {:ok, %EnvFile{} = env_file} <- %EnvFile{} |> EnvFile.changeset(attrs) |> Ecto.Changeset.apply_action(:save) do
      Git.save_env_file(project, EnvFile.to_text(env_file))
    end
  end
end
