defmodule Rail.Git.Actions.BranchFingerprint do
  @moduledoc false

  alias Rail.Tools

  @doc """
  Computes a fingerprint snapshot of a worktree's HEAD SHA and working-copy status.

  Returns nil if git cannot answer.
  """
  def branch_fingerprint(worktree_path) when is_binary(worktree_path) do
    with {head_out, 0} <-
           Tools.run("git", ["rev-parse", "HEAD"], cd: worktree_path, stderr_to_stdout: true),
         head_sha = String.trim(head_out),
         true <- head_sha != "",
         {status_out, 0} <-
           Tools.run("git", ["status", "--porcelain", "--untracked-files=all"],
             cd: worktree_path,
             stderr_to_stdout: true
           ) do
      dirty_digest =
        :sha256
        |> :crypto.hash(status_out)
        |> Base.encode16(case: :lower)

      %{
        head_sha: head_sha,
        dirty_digest: dirty_digest
      }
    else
      _other ->
        nil
    end
  end
end
