defmodule Rail.Tools.Actions.EnsureToolchain do
  @moduledoc false

  import Rail.Tools.Utils.RequestToolchainInstall

  alias Rail.Projects.Schemas.Project
  alias Rail.Tools

  @doc """
  Queues `project`'s toolchain command for the commit its fetched default branch
  is at, unless it has already run for that commit. Returns `{:ok, install}`, or
  `:ok` for a project with no command or no fetched branch.
  """
  def ensure_toolchain(%Project{toolchain_command: command}) when command in [nil, ""], do: :ok

  def ensure_toolchain(%Project{} = project) do
    case Tools.run("git", ["rev-parse", "--verify", "--quiet", "refs/remotes/origin/#{project.default_branch}"],
           cd: project.clone_path
         ) do
      {head_sha, 0} -> request_toolchain_install(project, String.trim(head_sha))
      {_output, _code} -> :ok
    end
  end
end
