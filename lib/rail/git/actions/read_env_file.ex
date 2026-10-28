defmodule Rail.Git.Actions.ReadEnvFile do
  @moduledoc false

  alias Rail.Projects.Schemas.Project

  @doc """
  `{:ok, text}` of `project`'s `.env` in its clone, `{:ok, ""}` when the clone has none, or `{:error, posix}`.
  """
  def read_env_file(%Project{clone_path: clone}) do
    case File.read(Path.join(clone, ".env")) do
      {:ok, text} -> {:ok, text}
      {:error, :enoent} -> {:ok, ""}
      {:error, reason} -> {:error, reason}
    end
  end
end
