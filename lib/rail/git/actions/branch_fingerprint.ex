defmodule Rail.Git.Actions.BranchFingerprint do
  @moduledoc false

  alias Rail.Git.BranchFingerprint
  alias Rail.Tools

  @doc """
  Computes a fingerprint snapshot of a worktree's HEAD SHA and working-copy status.

  `.rail/` is left out of the working-copy digest: agents write their own
  reports and manifests there, so counting it would make every run look like it
  changed the tree. Returns nil if git cannot answer.
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
        |> :crypto.hash(filter_rail_status(status_out))
        |> Base.encode16(case: :lower)

      %BranchFingerprint{
        head_sha: head_sha,
        dirty_digest: dirty_digest
      }
    else
      _other ->
        nil
    end
  end

  defp filter_rail_status(status_out) do
    status_out
    |> String.split(~r/\r?\n/)
    |> Enum.filter(&keep_status_line?/1)
    |> Enum.join("\n")
  end

  defp keep_status_line?(line) do
    case String.trim(line) do
      "" ->
        false

      _trimmed ->
        path =
          line
          |> String.slice(3..-1//1)
          |> String.trim()
          |> String.replace("\"", "")

        not String.starts_with?(path, ".rail/") and path != ".rail"
    end
  end
end
