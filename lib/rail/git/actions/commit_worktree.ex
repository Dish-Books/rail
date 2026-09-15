defmodule Rail.Git.Actions.CommitWorktree do
  @moduledoc """
  Commits everything in a task's worktree, as the person the ticket belongs to.

  The identity and the signing key are resolved here rather than handed in: who a
  commit is by is a question about the task, and a caller that had to answer it
  could answer it differently. The commit is authored by the ticket's assignee and
  signed with the key they registered; a ticket with nobody on it commits as the
  Rail bot, unsigned.

  Author and committer are set together with `-c user.*`, because GitHub verifies
  an SSH signature against the account owning the **committer** email: splitting
  them would publish a commit that never verifies.
  """

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Tools
  alias Rail.Users.Schemas.User

  @doc """
  Stages `task`'s worktree and commits it with `message`.

  Returns `{:ok, sha}`, or `{:error, :nothing_to_commit}` when staging found
  nothing, or `{:error, output}` when git refused.
  """
  def commit_worktree(%Scope{}, %Task{} = task, message) when is_binary(message) do
    # Forced, because who the ticket is assigned to may have changed since
    # whatever loaded this task read it, and that is who the commit belongs to.
    author = task |> Repo.preload([issue: :owner_user], force: true) |> Map.fetch!(:issue) |> author()

    with :ok <- stage(task.worktree_path),
         :ok <- with_signing_key(author, &commit(task.worktree_path, author, message, &1)) do
      head(task.worktree_path)
    end
  end

  # `.rail/` is the agents' own scratch inside the worktree and never part of the
  # change, so it is excluded here rather than left to a .gitignore Rail does not
  # own.
  defp stage(worktree_path) do
    case Tools.run("git", ["add", "-A", "--", ".", ":!.rail"], cd: worktree_path, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, _code} -> {:error, String.trim(output)}
    end
  end

  defp commit(worktree_path, author, message, signing_key_path) do
    args =
      ["-c", "user.name=#{author.name}", "-c", "user.email=#{author.email}"] ++
        signing_args(signing_key_path) ++
        ["commit", "-m", message]

    case Tools.run("git", args, cd: worktree_path, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, _code} -> staged_nothing_or_error(output)
    end
  end

  defp signing_args(path) when is_binary(path) do
    ["-c", "gpg.format=ssh", "-c", "user.signingkey=#{path}", "-c", "commit.gpgsign=true"]
  end

  defp signing_args(_unsigned), do: []

  defp staged_nothing_or_error(output) do
    if String.contains?(output, "nothing to commit") do
      {:error, :nothing_to_commit}
    else
      {:error, String.trim(output)}
    end
  end

  defp head(worktree_path) do
    case Tools.run("git", ["rev-parse", "HEAD"], cd: worktree_path, stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, String.trim(output)}

      # coveralls-ignore-start (a commit that just succeeded always has a HEAD to read)
      {output, _code} ->
        {:error, String.trim(output)}
        # coveralls-ignore-stop
    end
  end

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
