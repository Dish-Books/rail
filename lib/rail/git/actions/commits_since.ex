defmodule Rail.Git.Actions.CommitsSince do
  @moduledoc false

  import Rail.Git.Utils.WorkTree

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Tools

  @doc """
  Says how `task`'s branch came from `sha`: `{:ok, %{merges: boolean}}`, true when a merge commit lies between them,
  or `{:error, :not_ancestor}` when `sha` is not an ancestor of the branch or git cannot read it.
  """
  def commits_since(%Task{} = task, sha) when is_binary(sha) do
    with %{repo: repo, head: head} <- work_tree(task),
         {_output, 0} <- git(repo, ["merge-base", "--is-ancestor", sha, head]),
         {count, 0} <- git(repo, ["rev-list", "--count", "--merges", "#{sha}..#{head}"]) do
      {:ok, %{merges: String.trim(count) != "0"}}
    else
      _not_ancestor_or_unreadable -> {:error, :not_ancestor}
    end
  end

  defp git(repo, args), do: Tools.run("git", args, cd: repo, stderr_to_stdout: true)
end
