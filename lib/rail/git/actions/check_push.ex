defmodule Rail.Git.Actions.CheckPush do
  @moduledoc """
  Says whether a task's branch extends what its remote branch holds, which a push that is never forced
  needs, and why not when it does not: the branch rewrote commits it once had, which the agents may not
  do, or someone pushed to it outside Rail. Either way, merging `origin/<branch>` in is the way on.
  """

  import Rail.Git.Utils.WithCloneLock

  alias Rail.Git
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Tools

  @doc """
  Fetches `task`'s branch from `origin` and checks HEAD against it. Returns `:ok` when HEAD holds all of
  it, or the remote has no such branch or cannot be read, so the push says what is wrong;
  `{:error, :history_rewritten}` when the remote's tip is a commit the branch once held; and
  `{:error, :pushed_outside_rail}` when it is one the branch never had.
  """
  def check_push(%Task{worktree_path: worktree_path, worktree_name: branch} = task) do
    project = Repo.get!(Project, task.project_id)

    with {:ok, env} <- Git.credential_env(project),
         {_fetched, 0} <- fetch(project, worktree_path, branch, env),
         {_output, 1} <- git(worktree_path, ["merge-base", "--is-ancestor", "origin/#{branch}", "HEAD"]) do
      if held?(worktree_path, branch), do: {:error, :history_rewritten}, else: {:error, :pushed_outside_rail}
    else
      _pushable_or_unknown -> :ok
    end
  end

  # Fetched with the token into the project's clone, whose config is Rail's, then copied from there into the
  # checkout, whose config the sandbox could have pointed at another host. The copy needs no token.
  defp fetch(%Project{clone_path: clone_path}, worktree_path, branch, env) do
    ref = "refs/remotes/origin/#{branch}"

    with_clone_lock(clone_path, fn ->
      with {_fetched, 0} <-
             Tools.run("git", ["fetch", "--quiet", "origin", "+refs/heads/#{branch}:#{ref}"],
               cd: clone_path,
               env: env,
               stderr_to_stdout: true
             ),
           do: git(worktree_path, ["fetch", "--quiet", "--no-tags", clone_path, "+#{ref}:#{ref}"])
    end)
  end

  # The branch's reflog has every tip it has been at, so the remote's tip is one it held when one of them
  # reaches it: `rev-list` lists the tip only when none does.
  defp held?(worktree_path, branch) do
    {tips, 0} = git(worktree_path, ["reflog", "show", "--format=%H", "refs/heads/#{branch}"])

    match?({"", 0}, git(worktree_path, ["rev-list", "-n", "1", "origin/#{branch}", "--not" | String.split(tips)]))
  end

  defp git(worktree_path, args), do: Tools.run("git", args, cd: worktree_path, stderr_to_stdout: true)
end
