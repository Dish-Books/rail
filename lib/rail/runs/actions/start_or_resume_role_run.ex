defmodule Rail.Runs.Actions.StartOrResumeRoleRun do
  @moduledoc false

  import Ecto.Query

  alias Rail.Git
  alias Rail.Repo
  alias Rail.Runs.Schemas.RoleRun

  @doc """
  Marks the role run for a task/role pair as running, creating it on first use.

  A resumed role run keeps its history and bumps `attempts`; a new one starts at
  1. The worktree is fingerprinted here and stamped on the row, so later gates
  can tell whether the tree moved underneath them.
  """
  def start_or_resume_role_run(task, role, worktree_path) do
    {head_sha, dirty_digest} = fingerprint(worktree_path)

    attrs = %{
      status: :running,
      started_at: DateTime.utc_now(),
      stage_fingerprint_head_sha: head_sha,
      stage_fingerprint_dirty_digest: dirty_digest
    }

    case Repo.one(from r in RoleRun, where: r.task_id == ^task.id and r.role_id == ^role.id) do
      %RoleRun{} = existing ->
        existing
        |> RoleRun.changeset(Map.put(attrs, :attempts, (existing.attempts || 0) + 1))
        |> Repo.update()

      nil ->
        %RoleRun{}
        |> RoleRun.changeset(Map.merge(attrs, %{task_id: task.id, role_id: role.id, attempts: 1}))
        |> Repo.insert()
    end
  end

  defp fingerprint(worktree_path) when is_binary(worktree_path) and worktree_path != "" do
    case Git.branch_fingerprint(worktree_path) do
      %{head_sha: sha, dirty_digest: digest} -> {sha, digest}
      _other -> {nil, nil}
    end
  end

  defp fingerprint(_worktree_path), do: {nil, nil}
end
