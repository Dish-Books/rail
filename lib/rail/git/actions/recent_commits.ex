defmodule Rail.Git.Actions.RecentCommits do
  @moduledoc false

  import Rail.Git.Utils.GitCmd

  alias Rail.Git.CommitInfo

  @doc """
  Returns recent commits from the worktree's HEAD.
  """
  def recent_commits(worktree_path, opts \\ []) when is_binary(worktree_path) do
    limit = Keyword.get(opts, :limit, 15)

    case git_cmd(["log", "-n", to_string(limit), "--pretty=format:%H|%h|%s|%an|%cr"],
           cd: worktree_path,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        parse_commits(output)

      _error ->
        []
    end
  end

  defp parse_commits(output) do
    for line <- String.split(output, ~r/\r?\n/, trim: true),
        parts = String.split(String.trim(line), "|"),
        length(parts) >= 5 do
      [sha, short_sha, message, author, date | _rest] = parts

      %CommitInfo{
        sha: sha,
        short_sha: short_sha,
        message: message,
        author: author,
        date: date
      }
    end
  end
end
