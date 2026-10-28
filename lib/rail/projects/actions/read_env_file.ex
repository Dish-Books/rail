defmodule Rail.Projects.Actions.ReadEnvFile do
  @moduledoc false

  alias Rail.Git
  alias Rail.Projects.Schemas.EnvFile
  alias Rail.Projects.Schemas.Project

  @doc """
  `{:ok, env_file}` of the variables `project`'s clone's `.env` sets, or `{:error, posix}` when it cannot be read.
  """
  def read_env_file(_scope, %Project{} = project) do
    # The file is anyone's on the machine, so bytes that are not UTF-8 are shown replaced rather than crash the page.
    with {:ok, text} <- Git.read_env_file(project) do
      env_file = text |> String.replace_invalid() |> EnvFile.from_text()
      {:ok, env_file}
    end
  end
end
