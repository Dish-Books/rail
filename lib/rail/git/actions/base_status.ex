defmodule Rail.Git.Actions.BaseStatus do
  @moduledoc """
  Says how a task's branch stands against the default branch as last fetched: whether it is behind, and the files a
  merge of it would conflict in. The merge is worked out by `git merge-tree` without touching the worktree, so it
  is safe while an agent works there.
  """

  alias Rail.Tools

  @doc """
  Returns `%{behind: boolean, conflicts: [path]}` for the worktree's HEAD against `origin/<base_branch>`. A branch
  git cannot read is taken as up to date with nothing in conflict, since nothing can be said about it.
  """
  def base_status(worktree_path, base_branch) when is_binary(worktree_path) and is_binary(base_branch) do
    if up_to_date?(worktree_path, base_branch),
      do: %{behind: false, conflicts: []},
      else: %{behind: true, conflicts: conflicts(worktree_path, base_branch)}
  end

  defp up_to_date?(worktree_path, base_branch) do
    not match?({_output, 1}, git(worktree_path, ["merge-base", "--is-ancestor", "origin/#{base_branch}", "HEAD"]))
  end

  # A merge that conflicts exits 1, its tree's id on the first line and each conflicted file on a line of its own.
  defp conflicts(worktree_path, base_branch) do
    case git(worktree_path, [
           "merge-tree",
           "--write-tree",
           "--name-only",
           "--no-messages",
           "HEAD",
           "origin/#{base_branch}"
         ]) do
      {output, 1} -> output |> String.split("\n", trim: true) |> Enum.drop(1) |> Enum.uniq()
      {_output, _clean_or_unreadable} -> []
    end
  end

  defp git(worktree_path, args), do: Tools.run("git", args, cd: worktree_path, stderr_to_stdout: true)
end
