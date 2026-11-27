defmodule Rail.Git.Actions.BranchFingerprint do
  @moduledoc false

  import Rail.Git.Utils.WorkTree

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Tools

  @doc """
  A snapshot of `task`'s branch: the commit it is at, and a digest of which files its working tree changed on top
  of that and how, as its status lists them.

  Returns nil if git cannot answer.
  """
  def branch_fingerprint(%Task{} = task) do
    with %{repo: repo, head: head, work: work} <- work_tree(task),
         {status, 0} <- Tools.run("git", ["diff", "--name-status", "-z", head, work], cd: repo, stderr_to_stdout: true) do
      %{head_sha: head, dirty_digest: :sha256 |> :crypto.hash(status) |> Base.encode16(case: :lower)}
    else
      _unreadable -> nil
    end
  end
end
