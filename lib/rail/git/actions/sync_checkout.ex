defmodule Rail.Git.Actions.SyncCheckout do
  @moduledoc """
  Brings a task's repository up to date with its checkout: the branch as the checkout has it, its CI receipts, and its
  uncommitted work as `refs/rail/wip`, a commit on the branch whose tree is the working tree, untracked files in and
  ignored ones out. Under the `:docker` runtime the sandbox pushes them itself when asked; under `:local` Rail pushes
  them from the checkout, which is on its own disk.
  """

  import Rail.Git.Utils.LocalCheckout
  import Rail.Git.Utils.TaskBranch
  import Rail.Git.Utils.WithCloneLock

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Tools

  # Fixed, so a snapshot of the same work is the same commit whoever's checkout it is.
  @wip_identity %{
    "GIT_AUTHOR_NAME" => "Rail",
    "GIT_AUTHOR_EMAIL" => "rail@localhost",
    "GIT_COMMITTER_NAME" => "Rail",
    "GIT_COMMITTER_EMAIL" => "rail@localhost"
  }

  @doc """
  Syncs `task`'s checkout into its repository, unless a sync started within `Rail.checkout_sync_ms/0`, since a diff
  reads it many times over; `fresh: true` syncs regardless. Returns `:ok`, also when there is no checkout to sync or
  its sandbox is stopped, having synced before it stopped, or `{:error, reason}`.
  """
  def sync_checkout(%Task{} = task, opts \\ []) do
    key = {Rail.Git, :synced, task.id}
    window = Rail.checkout_sync_ms()

    # One at a time per task, so a read waiting on another's sync finds it done rather than syncing again.
    with_clone_lock(Task.repo_path(task), fn ->
      started = :persistent_term.get(key, nil)
      now = System.monotonic_time(:millisecond)

      if opts[:fresh] != true and is_integer(started) and now - started < window do
        :ok
      else
        # Written only when kept, since each write of a persistent term costs the node a sweep.
        if window > 0, do: :persistent_term.put(key, now)
        sync(Rail.sandbox_runtime(), task)
      end
    end)
  end

  defp sync(:docker, %Task{worktree_path: path} = task) do
    case Tools.call_sandbox(task, "sync", %{"path" => path, "branch" => task_branch(task)}) do
      {:ok, _synced} -> :ok
      {:error, :not_running} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp sync(:local, %Task{} = task) do
    case local_checkout(task) do
      checkout when is_binary(checkout) -> push(task, checkout)
      nil -> :ok
    end
  end

  defp push(%Task{} = task, checkout) do
    with {:ok, wip} <- snapshot(checkout),
         {:ok, _pushed} <-
           git(checkout, [
             "push",
             "--quiet",
             "--force",
             "--no-verify",
             Task.repo_path(task),
             "HEAD:refs/heads/#{task_branch(task)}",
             "refs/ci-receipts/*:refs/ci-receipts/*",
             "#{wip}:refs/rail/wip"
           ]) do
      :ok
    end
  end

  # Built in an index of its own, so the checkout's own index, which an agent may be committing from, is left alone.
  # A file git cannot read is left out rather than failing the rest, and fails `add` only after the others are in.
  defp snapshot(checkout) do
    index = Path.join(System.tmp_dir!(), "rail-wip-#{System.unique_integer([:positive])}.index")
    env = Map.put(@wip_identity, "GIT_INDEX_FILE", index)

    try do
      with {:ok, _read} <- git(checkout, ["read-tree", "HEAD"], env),
           _added = git(checkout, ["add", "--all", "--ignore-errors"], env),
           {:ok, tree} <- git(checkout, ["write-tree"], env) do
        git(checkout, ["commit-tree", "--no-gpg-sign", "-p", "HEAD", "-m", "Uncommitted work", tree], env)
      end
    after
      File.rm(index)
    end
  end

  defp git(path, args, env \\ %{}) do
    case Tools.run("git", args, cd: path, env: env, stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, _code} -> {:error, String.trim(output)}
    end
  end
end
