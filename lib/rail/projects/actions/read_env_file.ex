defmodule Rail.Projects.Actions.ReadEnvFile do
  @moduledoc false

  alias Rail.Git
  alias Rail.Projects.Schemas.EnvFile
  alias Rail.Projects.Schemas.Project

  @doc """
  `project`'s `.env`, as the variables its clone's file sets.
  """
  def read_env_file(_scope, %Project{} = project) do
    # The file is anyone's on the machine, so bytes that are not UTF-8 are shown replaced rather than crash the page.
    project |> Git.read_env_file() |> String.replace_invalid() |> EnvFile.from_text()
  end
end
