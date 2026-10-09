defmodule Rail.Git.Actions.LoadBranchHistory do
  @moduledoc """
  The branch's own commits along its first parent, newest first, each labeled by what made it: the
  engineer, a fix round by the step trailer Rail wrote on it, or a merge of the default branch.
  """

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Tools

  @field <<31>>
  @record <<30>>
  @step ~r/^Rail-Step: (Fix round \d+)\s*$/m

  @doc """
  Returns `task`'s commits as `%{sha:, short_sha:, subject:, at:, label:}`, newest first, or `[]` when
  git cannot read the branch.
  """
  def load_branch_history(%Task{worktree_path: worktree_path} = task) do
    %Project{default_branch: base} = Repo.get!(Project, task.project_id)
    format = Enum.join(["%H", "%h", "%s", "%cI", "%P", "%B"], @field) <> @record

    case Tools.run("git", ["log", "--first-parent", "--format=#{format}", "origin/#{base}..HEAD"],
           cd: worktree_path,
           stderr_to_stdout: true
         ) do
      {output, 0} -> output |> String.split(@record, trim: true) |> Enum.flat_map(&commit/1)
      _unreadable -> []
    end
  end

  defp commit(record) do
    case String.split(String.trim_leading(record), @field) do
      [sha, short_sha, subject, at, parents, body] ->
        {:ok, at, _offset} = DateTime.from_iso8601(at)
        [%{sha: sha, short_sha: short_sha, subject: subject, at: at, label: label(parents, body)}]

      _malformed ->
        []
    end
  end

  defp label(parents, body) do
    cond do
      length(String.split(parents)) > 1 -> "Merge main"
      step = Regex.run(@step, body, capture: :all_but_first) -> hd(step)
      true -> "Engineer"
    end
  end
end
