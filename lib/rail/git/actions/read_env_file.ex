defmodule Rail.Git.Actions.ReadEnvFile do
  @moduledoc false

  alias Rail.Projects.Schemas.Project

  @doc """
  The text of `project`'s `.env`, in its clone, or `""` when the clone has none.
  """
  def read_env_file(%Project{clone_path: clone}) do
    case File.read(Path.join(clone, ".env")) do
      {:ok, text} -> text
      {:error, :enoent} -> ""
    end
  end
end
