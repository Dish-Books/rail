defmodule Rail.Git.Actions.LoadBranchHistory do
  @moduledoc """
  The branch's own commits along its first parent, newest first, each labeled by what made it: a merge
  of the default branch or of what was pushed to the branch itself, the engineer's work before Review's first
  round read it, or the fix round whose commits came after that round's read. Each carries its stat against its first parent, so a merge's is
  what main brought in, and a merge the conflicts git met in it.
  """

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Tools

  @field <<31>>
  @record <<30>>

  @doc """
  Returns `task`'s branch as `%{base:, head:, files:, additions:, deletions:, commits:}`: the default
  branch's name, HEAD's short sha, and what the branch changed in all since it forked. `rounds` are the
  commits Review's rounds read, in order, which label what came between them. Each commit is `%{sha:,
  short_sha:, parent:, subject:, at:, label:, merge?:, main?:, merged:, conflicts:, files:, additions:,
  deletions:}`, with `merged` the commit a merge brought in and `main?` whether that is the default branch's.
  A branch git cannot read has no commits and no head.
  """
  def load_branch_history(%Task{worktree_path: worktree_path} = task, rounds) do
    %Project{default_branch: base} = Repo.get!(Project, task.project_id)
    format = @record <> Enum.join(["%H", "%h", "%p", "%s", "%cI"], @field) <> @field

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
      branch = %{worktree_path: worktree_path, base: base, name: task.worktree_name}
      read = Enum.map(rounds, &read_by(worktree_path, base, &1))
      commits = log |> String.split(@record, trim: true) |> Enum.flat_map(&commit(&1, branch, read))

      Map.merge(%{base: base, head: String.trim(head), commits: commits}, numstat(stat))
    else
      _unreadable -> %{base: base, head: nil, commits: [], files: 0, additions: 0, deletions: 0}
    end
  end

  # The branch's commits a round read; one a rebase has since replaced is no longer on the branch.
  defp read_by(worktree_path, base, head) do
    case Tools.run("git", ["rev-list", "origin/#{base}..#{head}"], cd: worktree_path, stderr_to_stdout: true) do
      {shas, 0} -> MapSet.new(String.split(shas))
      _gone -> MapSet.new()
    end
  end

  defp commit(record, %{worktree_path: worktree_path} = branch, read) do
    case String.split(record, @field) do
      [sha, short_sha, parents, subject, at, stat] ->
        {:ok, at, _offset} = DateTime.from_iso8601(at)
        parents = String.split(parents)
        main? = main?(branch, parents)

        [
          Map.merge(
            %{
              sha: sha,
              short_sha: short_sha,
              parent: List.first(parents),
              subject: subject,
              at: at,
              label: label(sha, parents, main?, branch, read),
              merge?: length(parents) > 1,
              main?: main?,
              merged: Enum.at(parents, 1),
              conflicts: conflicts(worktree_path, parents)
            },
            numstat(stat)
          )
        ]

      _malformed ->
        []
    end
  end

  # A merge brings in main when what it merged is on origin/<base>; otherwise it is what was pushed to the
  # branch itself, as merged when someone pushed to it outside Rail.
  defp main?(%{worktree_path: worktree_path, base: base}, [_first, second | _more]) do
    match?(
      {_output, 0},
      Tools.run("git", ["merge-base", "--is-ancestor", second, "origin/#{base}"],
        cd: worktree_path,
        stderr_to_stdout: true
      )
    )
  end

  defp main?(_branch, _parents), do: false

  defp label(_sha, [_first, _second | _more], true, _branch, _read), do: "Merge main"
  defp label(_sha, [_first, _second | _more], false, %{name: name}, _read), do: "Merge origin/#{name}"

  # The first round to read a commit is the one it was made before: none is the engineer's, round N's the
  # fix round N led to; one no round has read yet is the fix round under way.
  defp label(sha, _parents, _main?, _branch, read),
    do: read |> Enum.find_index(&MapSet.member?(&1, sha)) |> round_label(length(read))

  defp round_label(0, _rounds), do: "Engineer"
  defp round_label(nil, 0), do: "Engineer"
  defp round_label(nil, rounds), do: "Fix round #{rounds}"
  defp round_label(round, _rounds), do: "Fix round #{round}"

  # Git says which files the two sides changed apart; a merge with none had nothing to resolve.
  defp conflicts(worktree_path, [first, second]) do
    case Tools.run("git", ["merge-tree", "--write-tree", "--name-only", "--no-messages", first, second],
           cd: worktree_path,
           stderr_to_stdout: true
         ) do
      {output, 1} -> output |> String.split("\n", trim: true) |> length() |> Kernel.-(1)
      _clean -> 0
    end
  end

  defp conflicts(_worktree_path, _parents), do: 0

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
