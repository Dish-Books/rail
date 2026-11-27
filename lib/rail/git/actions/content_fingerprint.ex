defmodule Rail.Git.Actions.ContentFingerprint do
  @moduledoc false

  import Rail.Git.Utils.WorkTree

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Tools

  @rail_excluded [".", ":(exclude).rail"]

  @doc """
  Fingerprints `task`'s branch head and the contents of everything its working tree has on top of it.

  Unlike `branch_fingerprint/1`, rewriting a file that was already modified
  changes it, because it hashes contents rather than status lines. `.rail/` is
  left out for the same reason it is there. Returns nil if git cannot answer.
  """
  def content_fingerprint(%Task{} = task) do
    with %{repo: repo, head: head, work: work} <- work_tree(task),
         {diff, 0} <- Tools.run("git", ["diff", "--binary", head, work, "--" | @rail_excluded], cd: repo) do
      %{head_sha: head, content_digest: :sha256 |> :crypto.hash(diff) |> Base.encode16(case: :lower)}
    else
      _unreadable -> nil
    end
  end
end
