defmodule Rail.Pipeline.Utils.RoundChange do
  @moduledoc false

  alias Rail.Git
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Round
  alias Rail.Pipeline.Schemas.Task

  @doc """
  What `task`'s current round changed on its own, for the agents that check it: `%{number: n, base: sha, merged:
  boolean}` for a round after the first that started from a commit HEAD still comes from, `merged` true when it
  merged a branch in. `nil` when the round's change cannot be told from the whole branch's, so it is checked whole.
  """
  def round_change(%Task{worktree_path: worktree_path} = task) do
    with %Round{number: number, base_head: base, approved_at: %DateTime{}} when number > 1 and is_binary(base) <-
           Pipeline.read_plan(task),
         {:ok, %{merges: merged}} <- Git.commits_since(worktree_path, base) do
      %{number: number, base: base, merged: merged}
    else
      _whole_branch -> nil
    end
  end
end
