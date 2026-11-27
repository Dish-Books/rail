defmodule Rail.Git.Actions.PushBranch do
  @moduledoc """
  Pushes a commit of a task's branch to `origin`, with the CI receipt for its tree when CI passed on it.

  The credential is minted here from the project's GitHub App installation rather
  than passed in: a token is not something a caller should be holding, and the
  installation is what keeps a branch pushable after whoever was assigned leaves.

  The push goes from the project's clone, which fetches the commit from the task's
  repository after the checkout has synced into it, and pushes it with its own config.
  No hook runs, the project's or anyone's, and no git of Rail's runs where a sandbox writes.

  The receipt is `refs/ci-receipts/<tree>`, as the checkout holds it after CI wrote it
  there, and goes up only with the CI run that passed on that commit: Rail never vouches
  for a tree whose CI it did not see pass. The branch and the receipt land together or
  not at all, so a pull request never sees the one without the other.

  Never forced: the agents only ever add to a branch, merging its base in rather
  than rewriting its history, so a push that does not extend what the remote has
  is refused rather than overwritten. `check_push/1` says which way it would be.
  """

  import Rail.Git.Utils.LocalCheckout
  import Rail.Git.Utils.WithCloneLock

  alias Rail.Git
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess

  @receipts "refs/ci-receipts"
  @timeout_ms to_timeout(minute: 10)

  @doc """
  Pushes `commit` as `task`'s branch: the commit a passed CI run ran on, with its
  receipt, or for a project with no CI a commit SHA alone. Refuses a CI run that did
  not pass, or one with no commit recorded, and a nil SHA.
  """
  def push_branch(%Scope{}, %Task{} = task, %OsProcess{kind: :ci, exit_code: 0, head_sha: sha}) when is_binary(sha),
    do: push(task, sha, true)

  def push_branch(%Scope{}, %Task{} = task, sha) when is_binary(sha), do: push(task, sha, false)

  def push_branch(%Scope{}, %Task{}, %OsProcess{}),
    do: {:error, "This CI run did not pass on a commit Rail recorded, so nothing was pushed."}

  def push_branch(%Scope{}, %Task{}, nil), do: {:error, "git could not say which commit the branch is on."}

  defp push(%Task{worktree_name: branch} = task, sha, ci_passed?) do
    %Project{clone_path: clone_path} = project = Repo.get!(Project, task.project_id)
    repo = Task.repo_path(task)

    # Only an object name reaches git's argv, never something it could read as an option.
    with true <- sha =~ ~r/\A[0-9a-f]{40}([0-9a-f]{24})?\z/ || {:error, "#{inspect(sha)} is not a commit SHA."},
         # Synced however recently it last was, since CI writes its receipt just before this reads it; a commit the
         # sync did not bring is one the fetch below says is missing.
         _synced = Git.sync_checkout(task, fresh: true),
         {:ok, env} <- Git.credential_env(project),
         {:ok, receipt} <- with_clone_lock(clone_path, fn -> take(clone_path, repo, sha, ci_passed?) end),
         :ok <- git_push(clone_path, ["#{sha}:refs/heads/#{branch}" | receipt], env) do
      track(task, repo, branch, sha)
    end
  end

  # The commit, and its receipt when there is one to take, copied into the clone.
  defp take(clone_path, repo, sha, ci_passed?) do
    with :ok <- fetch(clone_path, repo, sha),
         {:ok, receipt} <- receipt(clone_path, repo, sha, ci_passed?) do
      case receipt do
        {ref, receipt_sha} ->
          with :ok <- fetch(clone_path, repo, receipt_sha), do: {:ok, ["+#{receipt_sha}:#{ref}"]}

        nil ->
          {:ok, []}
      end
    end
  end

  defp receipt(_clone_path, _repo, _sha, false), do: {:ok, nil}

  # The tree is read in the clone, from the commit it now holds, not taken from anything the checkout says.
  defp receipt(clone_path, repo, sha, true) do
    with {:ok, tree} <- git(clone_path, ["rev-parse", "--verify", "#{sha}^{tree}"]),
         ref = "#{@receipts}/#{tree}",
         {:ok, listed} <- git(clone_path, ["ls-remote", "--refs", repo, ref]) do
      # ls-remote matches the tail of a ref's name, so only the exact one counts.
      exact =
        listed
        |> String.split("\n", trim: true)
        |> Enum.find_value(fn line ->
          case String.split(line, "\t") do
            [receipt_sha, ^ref] -> {ref, receipt_sha}
            _other -> nil
          end
        end)

      {:ok, exact}
    end
  end

  defp fetch(clone_path, repo, sha) do
    with {:ok, _fetched} <- git(clone_path, ["fetch", "--quiet", "--no-tags", "--no-write-fetch-head", repo, sha]),
         do: :ok
  end

  defp git_push(clone_path, refspecs, env) do
    case Tools.run("git", ["push", "--quiet", "--no-verify", "--atomic", "origin" | refspecs],
           cd: clone_path,
           env: env,
           stderr_to_stdout: true,
           timeout: @timeout_ms
         ) do
      {_output, 0} -> :ok
      # coveralls-ignore-next-line (a push that runs for ten minutes)
      {:error, :timeout} -> {:error, "The push was still running after ten minutes, so it was stopped."}
      {output, code} when is_binary(output) and is_integer(code) -> {:error, String.trim(output)}
      # coveralls-ignore-next-line (git itself could not be started)
      {:error, reason} -> {:error, reason}
    end
  end

  # Origin's branch at the commit, where the repository's reads see it pushed; and in a checkout on Rail's disk
  # what `git push --set-upstream` from it would have left, so the agent's git counts it pushed too.
  defp track(%Task{} = task, repo, branch, sha) do
    ref = "refs/remotes/origin/#{branch}"

    with {:ok, _ref} <- git(repo, ["update-ref", ref, sha]) do
      case local_checkout(task) do
        checkout when is_binary(checkout) ->
          with {:ok, _ref} <- git(checkout, ["update-ref", ref, sha]),
               {:ok, _remote} <- git(checkout, ["config", "branch.#{branch}.remote", "origin"]),
               {:ok, _merge} <- git(checkout, ["config", "branch.#{branch}.merge", "refs/heads/#{branch}"]),
               do: :ok

        nil ->
          :ok
      end
    end
  end

  defp git(path, args) do
    case Tools.run("git", args, cd: path, stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, _code} -> {:error, String.trim(output)}
    end
  end
end
