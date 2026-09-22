defmodule Rail.Git.Actions.RebaseBranch do
  @moduledoc """
  Rebases a task's branch onto its project's default branch, or carries on with a
  rebase already under way.

  Every commit the rebase writes is committed as the ticket's owner and signed
  with their key, the same as the commits it replays, which is why Rail runs
  `--continue` rather than whoever resolved the conflict.
  """

  import Rail.Git.Utils.WithCommitIdentity

  alias Rail.Git
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Tools

  @doc """
  Rebases `task`'s branch onto `origin/<default branch>`, as fetched last.

  Returns `:ok` once the rebase is finished, `{:conflicts, files}` when it has
  stopped on files someone has to resolve, or `{:error, output}` when git refused
  for any other reason, having abandoned the rebase it started.
  """
  def rebase_branch(%Scope{}, %Task{worktree_path: worktree_path} = task) do
    %Project{default_branch: base} = Repo.get!(Project, task.project_id)

    args =
      if Git.rebase_in_progress?(worktree_path),
        do: ["rebase", "--continue"],
        else: ["rebase", "origin/#{base}"]

    with_commit_identity(task, fn identity ->
      # No editor to open: a continued commit keeps the message it had.
      case Tools.run("git", identity ++ args, cd: worktree_path, env: %{"GIT_EDITOR" => "true"}, stderr_to_stdout: true) do
        {_output, 0} -> :ok
        {output, _code} -> stopped(worktree_path, output)
      end
    end)
  end

  defp stopped(worktree_path, output) do
    case Git.conflicted_files(worktree_path) do
      [_file | _more] = files ->
        {:conflicts, files}

      [] ->
        _abandoned = Tools.run("git", ["rebase", "--abort"], cd: worktree_path, stderr_to_stdout: true)
        {:error, String.trim(output)}
    end
  end
end
