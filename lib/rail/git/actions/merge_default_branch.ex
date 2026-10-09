defmodule Rail.Git.Actions.MergeDefaultBranch do
  @moduledoc """
  Merges its project's default branch into a task's branch, or carries on with a
  merge already under way.

  A merge rather than a rebase: the branch's own commits stay as they were, so
  the pull request keeps its history and its review, and any conflict is met
  once, against where both sides ended up, rather than once per commit replayed.

  The merge commit is committed as the ticket's owner and signed with their key,
  the same as every other commit on the branch, which is why Rail runs
  `--continue` rather than whoever resolved the conflict. A merge that stopped on
  conflicts says in a `Rail-Conflicts` trailer how many it resolved.
  """

  import Rail.Git.Utils.WithCommitIdentity

  alias Rail.Git
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Tools

  @doc """
  Merges `origin/<default branch>`, as fetched last, into `task`'s branch.

  Returns `:ok` once the merge is committed, `{:conflicts, files}` when it has
  stopped on files someone has to resolve, or `{:error, output}` when git refused
  for any other reason, having abandoned the merge it started.
  """
  def merge_default_branch(%Scope{}, %Task{worktree_path: worktree_path} = task) do
    %Project{default_branch: base} = Repo.get!(Project, task.project_id)

    continuing? = Git.merge_in_progress?(worktree_path)

    # zdiff3 puts what the file was before either side changed it in every
    # conflict, so whoever resolves it can see what each side meant to do.
    args =
      if continuing?,
        do: ["merge", "--continue"],
        else: ["-c", "merge.conflictStyle=zdiff3", "merge", "--no-edit", "origin/#{base}"]

    with_commit_identity(task, fn identity ->
      # No editor to open: the merge commit keeps the message git wrote for it.
      case Tools.run("git", identity ++ args, cd: worktree_path, env: %{"GIT_EDITOR" => "true"}, stderr_to_stdout: true) do
        {_output, 0} -> :ok
        {output, _code} -> stopped(worktree_path, output, continuing?)
      end
    end)
  end

  defp stopped(worktree_path, output, continuing?) do
    case Git.conflicted_files(worktree_path) do
      [_file | _more] = files ->
        if not continuing?, do: count_conflicts(worktree_path, length(files))
        {:conflicts, files}

      [] ->
        _abandoned = Tools.run("git", ["merge", "--abort"], cd: worktree_path, stderr_to_stdout: true)
        {:error, String.trim(output)}
    end
  end

  # Written into the message `--continue` commits, since by then the conflicts are resolved and uncounted.
  defp count_conflicts(worktree_path, count) do
    {path, 0} = Tools.run("git", ["rev-parse", "--git-path", "MERGE_MSG"], cd: worktree_path, stderr_to_stdout: true)
    File.write!(Path.expand(String.trim(path), worktree_path), "\nRail-Conflicts: #{count}\n", [:append])
  end
end
