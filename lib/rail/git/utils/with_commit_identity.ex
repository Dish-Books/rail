defmodule Rail.Git.Utils.WithCommitIdentity do
  @moduledoc false

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Users.Schemas.User

  @doc """
  Calls `run` with the `-c` arguments that have git commit as the person `task`'s
  ticket belongs to, signed with their key, or as the Rail bot, unsigned.

  Author and committer are set together with `-c user.*`, because GitHub verifies
  an SSH signature against the account owning the **committer** email: splitting
  them would publish a commit that never verifies.
  """
  def with_commit_identity(%Task{} = task, run) when is_function(run, 1) do
    # Forced, because who the ticket is assigned to may have changed since
    # whatever loaded this task read it, and that is who the commit belongs to.
    author = task |> Repo.preload([issue: :owner_user], force: true) |> Map.fetch!(:issue) |> author()
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

  defp author(%Issue{owner_user: %User{} = user}) do
    %{
      name: user.name || user.login,
      email: user.email,
      signing_key: user.signing_key,
      signing_public_key: user.signing_public_key
    }
  end

  defp author(%Issue{}) do
    config = Application.get_env(:rail, :git, [])

    %{
      name: Keyword.get(config, :bot_name, "Rail"),
      email: Keyword.get(config, :bot_email, "rail[bot]@railai.dev"),
      signing_key: nil,
      signing_public_key: nil
    }
  end
end
