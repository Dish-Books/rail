defmodule Rail.Git.Actions.BranchFingerprint do
  @moduledoc false

  alias Rail.Git.BranchFingerprint
  alias Rail.Tools

  @doc """
  Computes a fingerprint snapshot of a worktree's HEAD SHA and working-copy status.
  Returns nil if git cannot answer.
  """
  def branch_fingerprint(worktree_path, opts \\ []) when is_binary(worktree_path) do
    ignore_rail? = Keyword.get(opts, :ignore_rail, false)

    with {head_out, 0} <-
           Tools.run("git", ["rev-parse", "HEAD"], cd: worktree_path, stderr_to_stdout: true),
         head_sha = String.trim(head_out),
         true <- head_sha != "",
         {status_out, 0} <-
           Tools.run("git", ["status", "--porcelain", "--untracked-files=all"],
             cd: worktree_path,
             stderr_to_stdout: true
           ) do
      effective_status =
        if ignore_rail? do
          filter_rail_status(status_out)
        else
          status_out
        end

      dirty_digest =
        :sha256
        |> :crypto.hash(effective_status)
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
