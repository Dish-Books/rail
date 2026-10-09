defmodule Rail.Tools.Actions.RetryToolchainInstall do
  @moduledoc false

  import Rail.Tools.Utils.RequestToolchainInstall

  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Tools.Schemas.ToolchainInstall

  @doc """
  Queues a failed install's commit again, with the project's command as it now
  stands, which nothing does on its own. Returns `{:ok, install}`, the new one or
  one already going, `{:error, :not_authorized}`, or `{:error, :no_command}`.
  """
  def retry_toolchain_install(%Scope{} = scope, %ToolchainInstall{project_id: project_id, head_sha: head_sha}) do
    with true <- Scope.can_access_project?(scope, project_id) || {:error, :not_authorized},
         %Project{toolchain_command: "" <> command} = project when command != "" <- Repo.get!(Project, project_id) do
      request_toolchain_install(project, head_sha, retry: true)
    else
      %Project{} -> {:error, :no_command}
      {:error, :not_authorized} -> {:error, :not_authorized}
    end
  end
end
