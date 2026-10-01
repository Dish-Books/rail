defmodule Rail.Git.Actions.ContentFingerprint do
  @moduledoc false

  alias Rail.Tools

  @rail_excluded [".", ":(exclude).rail"]

  @doc """
  Fingerprints a worktree's HEAD and the contents of everything on top of it.

  Unlike `branch_fingerprint/1`, rewriting a file that was already modified
  changes it, because it hashes contents rather than status lines. `.rail/` is
  left out for the same reason it is there. Returns nil if git cannot answer.
  """
  def content_fingerprint(worktree_path) when is_binary(worktree_path) do
    with {head_out, 0} <- git(worktree_path, ["rev-parse", "HEAD"]),
         {diff, 0} <- git(worktree_path, ["diff", "HEAD", "--binary", "--" | @rail_excluded]),
         {untracked_out, 0} <-
           git(worktree_path, ["ls-files", "--others", "--exclude-standard", "-z", "--" | @rail_excluded]),
         untracked = String.split(untracked_out, <<0>>, trim: true),
         {hashes, 0} <- hash_objects(worktree_path, untracked) do
      %{
        head_sha: String.trim(head_out),
        content_digest:
          :sha256
          |> :crypto.hash([diff, <<0>>, Enum.intersperse(untracked, <<0>>), <<0>>, hashes])
          |> Base.encode16(case: :lower)
      }
    else
      _unreadable -> nil
    end
  end

  defp hash_objects(_worktree_path, []), do: {"", 0}
  defp hash_objects(worktree_path, paths), do: git(worktree_path, ["hash-object", "--" | paths])

  defp git(worktree_path, args), do: Tools.run("git", args, cd: worktree_path, stderr_to_stdout: true)
end
