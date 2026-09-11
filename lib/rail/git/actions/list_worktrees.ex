defmodule Rail.Git.Actions.ListWorktrees do
  @moduledoc false

  alias Rail.Git.WorktreeInfo
  alias Rail.Tools

  @doc """
  Lists worktrees in a git repository by parsing porcelain output.
  """
  def list_worktrees(repo_path) when is_binary(repo_path) do
    case Tools.run("git", ["worktree", "list", "--porcelain"],
           cd: repo_path,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        parse_worktrees(output)

      _error ->
        []
    end
  end

  defp parse_worktrees(output) do
    lines = String.split(output, ~r/\r?\n/)

    {entries, current} =
      Enum.reduce(lines, {[], nil}, fn line, {acc, cur} ->
        cond do
          String.starts_with?(line, "worktree ") ->
            path = line |> String.replace_prefix("worktree ", "") |> String.trim()
            new_acc = flush(acc, cur)
            {new_acc, %{path: path, branch: "", commit_sha: "", is_bare: false}}

          String.starts_with?(line, "HEAD ") and cur != nil ->
            sha = line |> String.replace_prefix("HEAD ", "") |> String.trim()
            {acc, %{cur | commit_sha: sha}}

          String.starts_with?(line, "branch ") and cur != nil ->
            branch_ref = line |> String.replace_prefix("branch ", "") |> String.trim()
            branch = String.replace_prefix(branch_ref, "refs/heads/", "")
            {acc, %{cur | branch: branch}}

          String.trim(line) == "bare" and cur != nil ->
            {acc, %{cur | is_bare: true}}

          true ->
            {acc, cur}
        end
      end)

    entries
    |> flush(current)
    |> Enum.reverse()
  end

  defp flush(acc, nil), do: acc

  defp flush(acc, %{path: path, branch: branch, commit_sha: sha, is_bare: is_bare}) do
    info = %WorktreeInfo{
      path: path,
      branch: branch,
      commit_sha: sha,
      is_bare: is_bare
    }

    [info | acc]
  end
end
