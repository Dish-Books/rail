defmodule Rail.Pipeline.Utils.TurnStamp do
  @moduledoc """
  How the tree stood as an engineer turn past Engineer started, so its end can
  tell whether the turn changed code.
  """

  alias Rail.Git
  alias Rail.Pipeline.Schemas.Task

  @doc """
  The run fields stamping `task`'s worktree for a turn starting on it: its HEAD
  and content digest past Engineer, and nothing at any other stage.
  """
  def turn_stamp(%Task{stage: stage, worktree_path: worktree_path}) when stage in [:review, :qa, :demo] do
    fingerprint = Git.content_fingerprint(worktree_path)
    %{stage_fingerprint_head_sha: fingerprint[:head_sha], stage_fingerprint_dirty_digest: fingerprint[:content_digest]}
  end

  def turn_stamp(%Task{}), do: %{}
end
