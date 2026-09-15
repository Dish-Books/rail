defmodule Rail.Git.Actions.PushBranch do
  @moduledoc """
  Pushes a task's branch to `origin`.

  The credential is minted here from the project's GitHub App installation rather
  than passed in: a token is not something a caller should be holding, and the
  installation is what keeps a branch pushable after whoever was assigned leaves.
  It reaches git through a credential helper in the process environment and never
  through argv, where `ps` would show it — the same rule
  `Rail.Tools.Actions.BuildArgs` follows for the MCP token.
  """

  alias Rail.GitHub.Client, as: GitHub
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Tools

  @helper ~S|!f() { echo username=x-access-token; echo "password=$RAIL_GIT_TOKEN"; }; f|

  @doc """
  Pushes `task`'s branch, setting it to track `origin`.
  """
  def push_branch(%Scope{}, %Task{} = task) do
    with {:ok, token} <- token(task) do
      push(task.worktree_path, task.worktree_name, token)
    end
  end

  # Every project is required to name an installation, so there is nothing to fall
  # back to: a project that cannot be read is a broken invariant, not a branch to
  # handle.
  defp token(%Task{project_id: project_id}) do
    %Project{github_installation_id: installation_id} = Repo.get(Project, project_id)

    GitHub.installation_token(installation_id)
  end

  defp push(worktree_path, branch, token) do
    case Tools.run("git", ["push", "--set-upstream", "origin", branch],
           cd: worktree_path,
           env: env(token),
           stderr_to_stdout: true
         ) do
      {_output, 0} -> :ok
      {output, _code} -> {:error, String.trim(output)}
    end
  end

  defp env(token) do
    %{
      "RAIL_GIT_TOKEN" => token,
      "GIT_CONFIG_COUNT" => "1",
      "GIT_CONFIG_KEY_0" => "credential.helper",
      "GIT_CONFIG_VALUE_0" => @helper,
      "GIT_TERMINAL_PROMPT" => "0"
    }
  end
end
