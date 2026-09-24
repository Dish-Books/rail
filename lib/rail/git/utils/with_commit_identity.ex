defmodule Rail.Git.Utils.WithCommitIdentity do
  @moduledoc false

  import Rail.Git.Utils.CommitAuthor

  alias Rail.Pipeline.Schemas.Task

  @doc """
  Calls `run` with the `-c` arguments that have git commit as the person `task`'s
  ticket belongs to, signed with their key, or as the Rail bot, unsigned.

  Author and committer are set together with `-c user.*`, because GitHub verifies
  an SSH signature against the account owning the **committer** email: splitting
  them would publish a commit that never verifies.
  """
  def with_commit_identity(%Task{} = task, run) when is_function(run, 1) do
    author = commit_author(task)
    identity = ["-c", "user.name=#{author.name}", "-c", "user.email=#{author.email}"]

    with_signing_key(author, &run.(identity ++ signing_args(&1)))
  end

  defp signing_args(path) when is_binary(path) do
    ["-c", "gpg.format=ssh", "-c", "user.signingkey=#{path}", "-c", "commit.gpgsign=true"]
  end

  defp signing_args(_unsigned), do: []

  # The key never touches disk for longer than the commit takes. git reads the
  # private half by path and wants the public half beside it, so both are written
  # and both are removed.
  defp with_signing_key(%{signing_key: key, signing_public_key: public}, run) when is_binary(key) and is_binary(public) do
    path = Path.join(System.tmp_dir!(), UXID.generate!(prefix: "sig"))

    try do
      File.write!(path, key, [:exclusive])
      File.chmod!(path, 0o600)
      File.write!(path <> ".pub", public)
      run.(path)
    after
      File.rm(path)
      File.rm(path <> ".pub")
    end
  end

  defp with_signing_key(_unsigned, run), do: run.(nil)
end
