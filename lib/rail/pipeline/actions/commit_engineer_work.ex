defmodule Rail.Pipeline.Actions.CommitEngineerWork do
  @moduledoc """
  Commits and pushes what the engineer left in its worktree.

  Rail commits rather than the agent, because who a commit belongs to and what it
  is signed with are not decisions to leave to a prompt. What this stage owns is
  the message — the engineer's own words about the round, plus the trailers naming
  the ticket and Rail. Who the commit is by, what signs it and what pushes it are
  `Rail.Git`'s to answer.
  """

  import Rail.Pipeline.Utils.CommitMessage

  alias Rail.Git
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Commits everything in `task`'s worktree and pushes the branch.

  Returns `:ok`, or `{:error, reason}` when git or GitHub refused. Safe to run
  again after either half failed: it is the outstanding work it acts on, not a
  fixed pair of steps.
  """
  def commit_engineer_work(%Scope{} = scope, %Task{} = task) do
    task = Repo.preload(task, :issue)

    with {:ok, _sha} <- commit(scope, task),
         :ok <- Git.push_branch(scope, task) do
      drop_message_file(task)
      :ok
    end
  end

  # A push that failed leaves a commit that was made and never sent, so running
  # this again has nothing to commit and everything still to push.
  defp commit(%Scope{} = scope, %Task{worktree_path: worktree_path} = task) do
    if Git.worktree_dirty?(worktree_path),
      do: Git.commit_worktree(scope, task, commit_message(task, Pipeline.read_commit_message(task))),
      else: {:ok, :nothing_to_commit}
  end

  # The file being gone is what makes its absence mean something next round.
  defp drop_message_file(%Task{scratch_path: scratch_path, issue: %Issue{identifier: identifier}}) do
    [scratch_path, "commits", "#{identifier}.md"] |> Path.join() |> File.rm()
  end
end
