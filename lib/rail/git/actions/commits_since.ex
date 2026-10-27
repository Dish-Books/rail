defmodule Rail.Git.Actions.CommitsSince do
  @moduledoc false

  alias Rail.Tools

  @doc """
  Says how the worktree's HEAD came from `sha`: `{:ok, %{merges: boolean}}`, true when a merge commit lies between
  them, or `{:error, :not_ancestor}` when `sha` is not an ancestor of HEAD or git cannot read it.
  """
  def commits_since(worktree_path, sha) when is_binary(worktree_path) and is_binary(sha) do
    with {_output, 0} <- git(worktree_path, ["merge-base", "--is-ancestor", sha, "HEAD"]),
         {count, 0} <- git(worktree_path, ["rev-list", "--count", "--merges", "#{sha}..HEAD"]) do
      {:ok, %{merges: String.trim(count) != "0"}}
    else
      {_output, _not_ancestor_or_unreadable} -> {:error, :not_ancestor}
    end
  end

  defp git(worktree_path, args), do: Tools.run("git", args, cd: worktree_path, stderr_to_stdout: true)
end
