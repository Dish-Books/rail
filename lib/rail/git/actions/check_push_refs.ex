defmodule Rail.Git.Actions.CheckPushRefs do
  @moduledoc """
  Says whether a sandbox's push into its task's repository touches only what a sandbox may: the task's branch, its
  `refs/rail/wip` snapshot and CI receipts. Anything else in the repository, the remote branches Rail fetched above
  all, is Rail's, and the branch is never deleted.
  """

  import Rail.Git.Utils.TaskBranch

  alias Rail.Pipeline.Schemas.Task

  @doc """
  Checks each `{old_sha, new_sha, ref}` of a push into `task`'s repository, as receive-pack reads them. Returns `:ok`,
  or `{:error, ref}` for the first ref the push may not update.
  """
  def check_push_refs(%Task{} = task, ref_updates) when is_list(ref_updates) do
    branch = "refs/heads/" <> task_branch(task)

    Enum.find_value(ref_updates, :ok, fn {_old, new, ref} ->
      if allowed?(ref, new, branch), do: nil, else: {:error, ref}
    end)
  end

  # An all-zero new side is a delete.
  defp allowed?(branch, new, branch), do: not (new =~ ~r/\A0+\z/)
  defp allowed?("refs/rail/wip", _new, _branch), do: true
  defp allowed?("refs/ci-receipts/" <> tree, _new, _branch), do: tree =~ ~r/\A[0-9a-f]+\z/
  defp allowed?(_ref, _new, _branch), do: false
end
