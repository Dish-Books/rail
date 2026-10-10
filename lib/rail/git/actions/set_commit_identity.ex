defmodule Rail.Git.Actions.SetCommitIdentity do
  @moduledoc """
  Has a task's worktree commit as the person its ticket belongs to, signed with their key: the agent
  commits there itself. Written to the worktree's own config, so no other worktree of the clone commits as
  them, and kept for the worktree's life; set again before each turn, so a ticket that changed hands
  commits as its new owner. The key goes with the task's scratch folder.

  Author and committer are one identity, because GitHub verifies an SSH signature against the account
  owning the committer email. A ticket with nobody on it commits as the Rail bot, unsigned.
  """

  import Rail.Git.Utils.CommitAuthor

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Tools

  @doc """
  Writes `task`'s commit identity into its worktree's config. Returns `:ok`, or `{:error, output}` when git
  refused.
  """
  def set_commit_identity(%Task{worktree_path: worktree_path} = task) do
    author = commit_author(task)

    # A worktree reads a config of its own only once the clone says worktrees may have one.
    settings =
      [
        {nil, "extensions.worktreeConfig", "true"},
        {:worktree, "user.name", author.name},
        {:worktree, "user.email", author.email}
      ] ++
        signing(task, author)

    Enum.reduce_while(settings, :ok, fn {scope, key, value}, :ok ->
      case Tools.run("git", ["config" | args(scope)] ++ [key, value], cd: worktree_path, stderr_to_stdout: true) do
        {_output, 0} -> {:cont, :ok}
        {output, _code} -> {:halt, {:error, String.trim(output)}}
      end
    end)
  end

  defp args(:worktree), do: ["--worktree"]
  defp args(nil), do: []

  # The key sits in the task's scratch folder, which the sandbox sees and the commit never holds. With no
  # key the commits go unsigned rather than not at all, whatever the machine's own config says.
  defp signing(%Task{scratch_path: scratch_path}, %{signing_key: key, signing_public_key: public})
       when is_binary(key) and is_binary(public) do
    path = Path.join([scratch_path, ".signing", "key"])
    File.mkdir_p!(Path.dirname(path))
    File.rm(path)
    File.write!(path, key, [:exclusive])
    File.chmod!(path, 0o600)
    File.write!(path <> ".pub", public)

    [{:worktree, "gpg.format", "ssh"}, {:worktree, "user.signingkey", path}, {:worktree, "commit.gpgsign", "true"}]
  end

  defp signing(%Task{}, _unsigned), do: [{:worktree, "commit.gpgsign", "false"}]
end
