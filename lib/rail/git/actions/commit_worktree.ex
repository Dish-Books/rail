defmodule Rail.Git.Actions.CommitWorktree do
  @moduledoc """
  Commits everything in a task's worktree, as the person the ticket belongs to.

  The identity and the signing key are resolved here rather than handed in: who a
  commit is by is a question about the task, and a caller that had to answer it
  could answer it differently. The commit is authored by the ticket's assignee and
  signed with the key they registered; a ticket with nobody on it commits as the
  Rail bot, unsigned.
  """

  import Rail.Git.Utils.WithCommitIdentity

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Scope
  alias Rail.Tools

  @doc """
  Stages `task`'s worktree and commits it with `message`.

  Returns `{:ok, sha}`, or `{:error, :nothing_to_commit}` when staging found
  nothing, or `{:error, output}` when git refused.
  """
  def commit_worktree(%Scope{}, %Task{} = task, message) when is_binary(message) do
    with :ok <- stage(task.worktree_path),
         :ok <- with_commit_identity(task, &commit(task.worktree_path, message, &1)) do
      head(task.worktree_path)
    end
  end

  # `.rail/` is the agents' own scratch inside the worktree and never part of the
  # change, so it is excluded here rather than left to a .gitignore Rail does not
  # own.
  defp stage(worktree_path) do
    case Tools.run("git", ["add", "-A", "--", ".", ":!.rail"], cd: worktree_path, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, _code} -> {:error, String.trim(output)}
    end
  end

  defp commit(worktree_path, message, identity) do
    case Tools.run("git", identity ++ ["commit", "-m", message], cd: worktree_path, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, _code} -> staged_nothing_or_error(output)
    end
  end

  defp staged_nothing_or_error(output) do
    if String.contains?(output, "nothing to commit") do
      {:error, :nothing_to_commit}
    else
      {:error, String.trim(output)}
    end
  end

  defp head(worktree_path) do
    case Tools.run("git", ["rev-parse", "HEAD"], cd: worktree_path, stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, String.trim(output)}

      # coveralls-ignore-start (a commit that just succeeded always has a HEAD to read)
      {output, _code} ->
        {:error, String.trim(output)}
        # coveralls-ignore-stop
    end
  end
end
