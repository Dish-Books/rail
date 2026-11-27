defmodule Rail.Git.Actions.GitService do
  @moduledoc """
  The command a sandbox's `git` channel runs against its task's repository: `git upload-pack` for a fetch or clone,
  `git receive-pack` for a push, with the environment Rail's own git runs with, so the repository's config can name no
  hook or program. Its pushes are checked with `Rail.Git.check_push_refs/2` before receive-pack sees them.
  """

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Tools

  @doc """
  Returns `{executable, args, env}` to run `service`, `"git-upload-pack"` or `"git-receive-pack"`, for `task`, `env`
  being the whole environment it gets; or `{:error, :unsupported}` for any other service.
  """
  def git_service(%Task{} = task, "git-upload-pack"), do: command(task, ["upload-pack", "--strict", Task.repo_path(task)])

  def git_service(%Task{} = task, "git-receive-pack"), do: command(task, ["receive-pack", Task.repo_path(task)])
  def git_service(%Task{}, _service), do: {:error, :unsupported}

  defp command(%Task{} = task, args), do: Tools.build_command("git", args, cd: Task.repo_path(task))
end
