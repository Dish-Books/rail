defmodule Rail.Git.Actions.LoadBranchHistory do
  @moduledoc """
  The branch's own commits along its first parent, newest first, each labeled by what made it: the
  engineer, a fix round or a merge follow-up by the step trailer Rail wrote on it, or a merge of the
  default branch. Each carries its stat against its first parent, so a merge's is what main brought in.
  """

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Tools

  @field <<31>>
  @record <<30>>
  @step ~r/^Rail-Step: (Fix round \d+|Merge follow-up)\s*$/m
  @conflicts ~r/^Rail-Conflicts: (\d+)\s*$/m

  @doc """
  Returns `task`'s branch as `%{base:, head:, files:, additions:, deletions:, commits:}`: the default
  branch's name, HEAD's short sha, and what the branch changed in all since it forked. Each commit is
  `%{sha:, short_sha:, parent:, subject:, at:, label:, merge?:, merged:, conflicts:, files:, additions:,
  deletions:}`, with `merged` the default branch's commit a merge brought in. A branch git cannot read
  has no commits and no head.
  """
  def load_branch_history(%Task{worktree_path: worktree_path} = task) do
    %Project{default_branch: base} = Repo.get!(Project, task.project_id)
    format = @record <> Enum.join(["%H", "%h", "%p", "%s", "%cI", "%B"], @field) <> @field

    args = [
      "log",
      "--first-parent",
      "--diff-merges=first-parent",
      "--numstat",
      "--format=#{format}",
      "origin/#{base}..HEAD"
    ]

    with {log, 0} <- Tools.run("git", args, cd: worktree_path, stderr_to_stdout: true),
         {stat, 0} <- Tools.run("git", ["diff", "--numstat", "origin/#{base}...HEAD"], cd: worktree_path),
         {head, 0} <- Tools.run("git", ["rev-parse", "--short", "HEAD"], cd: worktree_path, stderr_to_stdout: true) do
      commits = log |> String.split(@record, trim: true) |> Enum.flat_map(&commit/1)

      Map.merge(%{base: base, head: String.trim(head), commits: commits}, numstat(stat))
    else
      _unreadable -> %{base: base, head: nil, commits: [], files: 0, additions: 0, deletions: 0}
    end
  end

  defp commit(record) do
    case String.split(record, @field) do
      [sha, short_sha, parents, subject, at, body, stat] ->
        {:ok, at, _offset} = DateTime.from_iso8601(at)
        parents = String.split(parents)

        [
          Map.merge(
            %{
              sha: sha,
              short_sha: short_sha,
              parent: List.first(parents),
              subject: subject,
              at: at,
              label: label(parents, body),
              merge?: length(parents) > 1,
              merged: Enum.at(parents, 1),
              conflicts: conflicts(body)
            },
            numstat(stat)
          )
        ]

      _malformed ->
        []
    end
  end

  defp label([_first, _second | _more], _body), do: "Merge main"

  defp label(_parents, body) do
    case Regex.run(@step, body, capture: :all_but_first) do
      [step] -> step
      nil -> "Engineer"
    end
  end

  defp conflicts(body) do
    case Regex.run(@conflicts, body, capture: :all_but_first) do
      [count] -> String.to_integer(count)
      nil -> 0
    end
  end

  # A binary file's lines are `-`, which count as none.
  defp numstat(stat) do
    rows =
      for line <- String.split(stat, "\n", trim: true),
          [added, deleted, _path] <- [String.split(line, "\t", parts: 3)],
          do: {added, deleted}

    %{
      files: length(rows),
      additions: Enum.sum_by(rows, &count(elem(&1, 0))),
      deletions: Enum.sum_by(rows, &count(elem(&1, 1)))
    }
  end

  defp count(number) do
    case Integer.parse(number) do
      {count, ""} -> count
      _binary -> 0
    end
  end
end
