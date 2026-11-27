defmodule Rail.Git.Actions.WriteCheckoutConfig do
  @moduledoc """
  Writes a task checkout's git config whole, from what Rail knows, over whatever is there, under the `:local`
  runtime: the only one whose checkouts are on Rail's disk, where Rail syncs them from. A sandbox's checkout gets its
  config with its `checkout` call instead (`Rail.Git.checkout_params/2`).

  It holds the repository's format, `origin` as the project's clone has it, the branch's upstream once Rail has pushed
  it, and who commits: the person the ticket belongs to, signed with their key, since the agent commits there itself.
  Written again before each turn, so a ticket that changed hands commits as its new owner. The key goes in the task's
  repository folder.

  Author and committer are one identity, because GitHub verifies an SSH signature against the account owning the
  committer email. A ticket with nobody on it commits as the Rail bot, unsigned.

  A task still on a worktree of its project's clone shares the clone's config, so it gets only its identity, in a
  config of the worktree's own, as before.
  """

  import Rail.Git.Utils.CommitAuthor
  import Rail.Git.Utils.SigningKeyFile

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Tools

  # As much of a clone's core settings as says how its files sit on this disk, taken from the project's clone.
  @disk ["filemode", "symlinks", "ignorecase", "precomposeunicode"]

  @doc """
  Writes `task`'s checkout config, `project` being its project. Returns `:ok`, or `{:error, output}` when git refused.
  """
  def write_checkout_config(%Project{} = project, %Task{worktree_path: worktree_path} = task) do
    git_dir = Path.join(worktree_path, ".git")

    cond do
      Rail.sandbox_runtime() != :local -> :ok
      File.dir?(git_dir) -> write(project, task, git_dir)
      true -> set(worktree_path, nil, worktree_identity(task))
    end
  end

  # Built beside the config and moved over it, so a failure midway leaves the last one whole, and of two at once the
  # later is the one kept.
  defp write(%Project{clone_path: clone_path}, %Task{worktree_path: worktree_path} = task, git_dir) do
    config = Path.join(git_dir, "config")
    building = "#{config}.rail-#{System.unique_integer([:positive])}"

    result =
      with {:ok, format} <- format(worktree_path),
           {:ok, origin} <- git(clone_path, ["remote", "get-url", "origin"]),
           settings =
             format ++
               disk(clone_path) ++
               [
                 {"core.bare", "false"},
                 {"core.logallrefupdates", "true"},
                 {"remote.origin.url", origin},
                 {"remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*"}
               ] ++ upstream(task, config) ++ identity(task),
           :ok <- set(worktree_path, building, settings) do
        # Read only when the config enables it, which this one does not; a sandbox's would be stale and is not kept.
        File.rm(Path.join(git_dir, "config.worktree"))
        File.rename!(building, config)
      end

    File.rm(building)
    result
  end

  # A clone of a clone has the format its source had, which git reads from the config this replaces: it says only
  # which of the formats it knows that is, and the repository can still be read in it.
  defp format(worktree_path) do
    with {:ok, formats} <- git(worktree_path, ["rev-parse", "--show-object-format", "--show-ref-format"]) do
      [objects, refs] = String.split(formats)

      {:ok,
       [
         {"core.repositoryformatversion", "1"},
         {"extensions.objectformat", objects},
         {"extensions.refstorage", refs}
       ]}
    end
  end

  defp disk(clone_path) do
    for key <- @disk,
        {value, 0} <- [Tools.run("git", ["config", "--type=bool", "--get", "core.#{key}"], cd: clone_path)],
        do: {"core.#{key}", String.trim(value)}
  end

  # The branch tracks origin's once Rail has pushed it, which Rail recorded in the config this replaces. Read as text,
  # with no file it names, and kept only as whether it was so: the values are Rail's own.
  defp upstream(%Task{} = task, config) do
    branch = task.worktree_name || task.id
    merge = "refs/heads/#{branch}"

    case git(Path.dirname(config), ["config", "--file", config, "--no-includes", "--get", "branch.#{branch}.merge"]) do
      {:ok, ^merge} -> [{"branch.#{branch}.remote", "origin"}, {"branch.#{branch}.merge", merge}]
      {_read, _other} -> []
    end
  end

  defp identity(%Task{} = task) do
    author = commit_author(task)
    [{"user.name", author.name}, {"user.email", author.email}] ++ signing(task, author)
  end

  # A worktree reads a config of its own only once the clone says worktrees may have one.
  defp worktree_identity(%Task{} = task) do
    [{"extensions.worktreeConfig", "true"} | Enum.map(identity(task), fn {key, value} -> {:worktree, key, value} end)]
  end

  defp set(worktree_path, file, settings) do
    Enum.reduce_while(settings, :ok, fn setting, :ok ->
      case git(worktree_path, ["config" | args(file, setting)]) do
        {:ok, _output} -> {:cont, :ok}
        {:error, output} -> {:halt, {:error, output}}
      end
    end)
  end

  defp args(_file, {:worktree, key, value}), do: ["--worktree", key, value]
  defp args(file, {key, value}) when is_binary(file), do: ["--file", file, key, value]
  defp args(nil, {key, value}), do: [key, value]

  defp git(path, args) do
    case Tools.run("git", args, cd: path, stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, _code} -> {:error, String.trim(output)}
    end
  end

  # With no key the commits go unsigned rather than not at all, whatever the machine's own config says.
  defp signing(%Task{} = task, %{signing_key: key, signing_public_key: public})
       when is_binary(key) and is_binary(public) do
    [
      {"gpg.format", "ssh"},
      {"gpg.ssh.program", "ssh-keygen"},
      {"user.signingkey", signing_key_file(task, key, public)},
      {"commit.gpgsign", "true"}
    ]
  end

  defp signing(%Task{}, _unsigned), do: [{"commit.gpgsign", "false"}]
end
