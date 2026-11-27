defmodule Rail.Git.Actions.BaseStatus do
  @moduledoc """
  Says how a task's branch stands against the default branch as last fetched: whether it is behind, and the files a
  merge of it would conflict in. The merge is worked out by `git merge-tree` in the task's repository, so it is
  safe while an agent works in the checkout.
  """

  import Rail.Git.Utils.WorkTree

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Tools

  @doc """
  Returns `%{behind: boolean, conflicts: [path]}` for `task`'s branch against `origin/<base_branch>`. A branch git
  cannot read is taken as up to date with nothing in conflict, since nothing can be said about it.
  """
  def base_status(%Task{} = task, base_branch) when is_binary(base_branch) do
    case work_tree(task) do
      %{repo: repo, head: head} ->
        if up_to_date?(repo, head, base_branch),
          do: %{behind: false, conflicts: []},
          else: %{behind: true, conflicts: conflicts(repo, head, base_branch)}

      nil ->
        %{behind: false, conflicts: []}
    end
  end

  defp up_to_date?(repo, head, base_branch) do
    not match?({_output, 1}, git(repo, ["merge-base", "--is-ancestor", "origin/#{base_branch}", head]))
  end

  # A merge that conflicts exits 1, its tree's id on the first line and each conflicted file on a line of its own.
  defp conflicts(repo, head, base_branch) do
    case git(repo, ["merge-tree", "--write-tree", "--name-only", "--no-messages", head, "origin/#{base_branch}"]) do
      {output, 1} -> output |> String.split("\n", trim: true) |> Enum.drop(1) |> Enum.uniq()
      {_output, _clean_or_unreadable} -> []
    end
  end

  defp git(repo, args), do: Tools.run("git", args, cd: repo, stderr_to_stdout: true)
end
