defmodule Rail.Git.Actions.GetOrCreateWorktree do
  @moduledoc false

  import Rail.Git.Utils.TaskBranch
  import Rail.Git.Utils.WithCloneLock
  import Rail.Git.Utils.WriteEnvBlock

  alias Rail.Git
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Tools

  @doc """
  Gets the task's repository or makes it, then under the `:local` runtime its checkout.

  The repository is bare and Rail's: its config is Rail's own, its objects are borrowed from the project's clone, and
  it holds the branch, the remote branches Rail fetched, and what the checkout last synced into it. A task with a pull
  request continues its branch as `origin` has it; any other starts a new one from `origin/<default branch>`, fetched
  first. A task whose checkout predates its repository takes the branch as `origin` has it when it is there, and its
  first sync brings in the rest.

  Under `:local` the checkout is a clone of the repository at `worktree_path`, pushing to the project's `origin`,
  with its git config written by Rail (`Rail.Git.write_checkout_config/2`). Under `:docker` the sandbox clones its
  own (`Rail.Git.checkout_params/2`).
  """
  def get_or_create_worktree(%Project{} = project, %Task{worktree_path: path} = task) when is_binary(path) do
    repo = Task.repo_path(task)

    # Two starts at once build in one place, so the second waits and then finds the first's repository and checkout.
    made =
      with_clone_lock(repo, fn ->
        with :ok <- make_repo(project, task, repo), do: checkout(Rail.sandbox_runtime(), project, task, repo)
      end)

    case made do
      :ok -> {:ok, path}
      {:error, reason} when is_binary(reason) -> {:error, "Failed to create the task's clone at #{path}: #{reason}"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp make_repo(%Project{} = project, %Task{} = task, repo) do
    if File.dir?(repo) do
      :ok
    else
      # Made beside its path and moved in last, so a failure or a restart midway leaves nothing to reuse.
      building = repo <> ".new"
      File.rm_rf!(building)
      File.mkdir_p!(Path.dirname(repo))

      with :ok <- Git.fetch_default_branch(project, project.clone_path),
           :ok <- init(project, building),
           :ok <- branch(project, task, building),
           :ok <- ok(git(building, ["symbolic-ref", "HEAD", "refs/heads/#{task_branch(task)}"])),
           :ok <- rename(building, repo) do
        :ok
      else
        {:error, reason} ->
          File.rm_rf!(building)
          {:error, reason}
      end
    end
  end

  # No template, so no sample hooks, and the clone's objects borrowed rather than copied.
  defp init(%Project{clone_path: clone, default_branch: default}, building) do
    ref = "refs/remotes/origin/#{default}"

    with {:ok, format} <- git(clone, ["rev-parse", "--show-object-format"]),
         {:ok, origin} <- git(clone, ["remote", "get-url", "origin"]),
         {:ok, objects} <- git(clone, ["rev-parse", "--path-format=absolute", "--git-path", "objects"]),
         {:ok, _made} <-
           git(Path.dirname(building), ["init", "--quiet", "--bare", "--template=", "--object-format=#{format}", building]) do
      File.mkdir_p!(Path.join(building, "objects/info"))
      File.write!(Path.join(building, "objects/info/alternates"), objects <> "\n")

      # A bare repository keeps no reflog unless told to, and check_push/1 reads the branch's.
      settings = [
        {"core.logallrefupdates", "true"},
        {"remote.origin.url", origin},
        {"remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*"}
      ]

      with :ok <- Enum.reduce_while(settings, :ok, &config(building, &1, &2)),
           do: ok(git(building, ["fetch", "--quiet", "--no-tags", "--no-write-fetch-head", clone, "+#{ref}:#{ref}"]))
    end
  end

  defp config(building, {key, value}, :ok) do
    case git(building, ["config", key, value]) do
      {:ok, _set} -> {:cont, :ok}
      {:error, output} -> {:halt, {:error, output}}
    end
  end

  # A checkout made before its repository has its branch only there, which no git of Rail's reads, so the branch
  # starts where origin has it, if anywhere, and the checkout's first sync moves it to where it is.
  defp branch(%Project{} = project, %Task{worktree_path: path} = task, building) do
    branch = task_branch(task)

    cond do
      File.exists?(Path.join(path, ".git")) ->
        with {:error, _not_on_origin} <- Git.fetch_branch(project, building, branch),
             do: new_branch(project, building, branch)

      is_integer(task.pr_number) ->
        Git.fetch_branch(project, building, branch)

      true ->
        new_branch(project, building, branch)
    end
  end

  # No upstream, so the branch reads as never pushed rather than as tracking the base.
  defp new_branch(%Project{default_branch: default}, building, branch),
    do: ok(git(building, ["branch", "--no-track", branch, "origin/#{default}"]))

  defp checkout(:docker, _project, _task, _repo), do: :ok

  defp checkout(:local, %Project{} = project, %Task{} = task, repo) do
    cond do
      File.dir?(Path.join(task.worktree_path, ".git")) -> Git.write_checkout_config(project, task)
      # A worktree of the project's clone shares the clone's config, which is not the task's to write; anything else
      # already at the path is someone's, and never made over.
      File.exists?(task.worktree_path) -> :ok
      true -> with :ok <- make_checkout(project, task, repo), do: Git.write_checkout_config(project, task)
    end
  end

  # A plain path rather than --local, which fails outright where git cannot hardlink.
  defp make_checkout(%Project{clone_path: clone} = project, %Task{worktree_path: path} = task, repo) do
    branch = task_branch(task)
    building = path <> ".new"
    File.rm_rf!(building)

    made =
      with {:ok, origin} <- git(clone, ["remote", "get-url", "origin"]),
           {:ok, _cloned} <- git(repo, ["clone", "--quiet", "--branch", branch, repo, building]),
           {:ok, _set} <- git(building, ["remote", "set-url", "origin", origin]),
           # A clone takes the repository's branches as origin's; origin's are the ones the repository fetched.
           {:ok, _fetched} <-
             git(building, [
               "fetch",
               "--quiet",
               "--prune",
               "--no-tags",
               repo,
               "+refs/remotes/origin/*:refs/remotes/origin/*"
             ]),
           {:ok, _untracked} <- git(building, ["branch", "--unset-upstream"]),
           :ok <- restore_wip(repo, building) do
        # With no script to wait on it gets the .env as it is made; otherwise the setup run copies it.
        # Under the clone's lock, as save_env_file/2 writes every task's .env under it.
        with_clone_lock(clone, fn ->
          env =
            if project.worktree_setup_script in [nil, ""],
              do: write_env_block(project, %{task | worktree_path: building}),
              else: :ok

          with :ok <- env, do: rename(building, path)
        end)
      end

    with {:error, reason} <- made do
      File.rm_rf!(building)
      {:error, reason}
    end
  end

  # A checkout made again over work its last one synced starts with that work in it, uncommitted as it was.
  # Only a snapshot taken on the branch's head is that work; one from an earlier head would undo commits.
  defp restore_wip(repo, building) do
    with {:ok, head} <- git(building, ["rev-parse", "HEAD"]),
         {:ok, shas} <- git(repo, ["rev-parse", "refs/rail/wip", "refs/rail/wip^"]),
         [wip, ^head] <- String.split(shas),
         {:ok, _read} <- git(building, ["read-tree", "-u", "--reset", wip]) do
      ok(git(building, ["reset", "--quiet"]))
    else
      _no_snapshot_on_the_head -> :ok
    end
  end

  defp rename(from, to) do
    case File.rename(from, to) do
      :ok -> :ok
      {:error, reason} -> {:error, "#{to}: #{:file.format_error(reason)}"}
    end
  end

  defp ok({:ok, _output}), do: :ok
  defp ok({:error, output}), do: {:error, output}

  defp git(path, args) do
    case Tools.run("git", args, cd: path, stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, _code} -> {:error, String.trim(output)}
    end
  end
end
