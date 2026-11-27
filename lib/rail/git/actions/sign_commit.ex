defmodule Rail.Git.Actions.SignCommit do
  @moduledoc """
  Signs a commit or tag a task's sandbox made, as `rail-sign` asks on git's behalf, with the key of the person the
  ticket belongs to, which never leaves Rail. Only an object that says it is theirs is signed: one whose committer, or
  a tag's tagger, is the task's identity, so a sandbox cannot have Rail vouch for anyone else's work.
  """

  import Rail.Git.Utils.CommitAuthor
  import Rail.Git.Utils.SigningKeyFile

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Tools

  @doc """
  Returns `{:ok, armored_signature}` for `payload`, the object git would sign, or `{:error, reason}`: `:no_signing_key`
  when the owner has none, `:not_a_commit` for anything but a well-formed commit or tag, `:not_the_task_identity`
  for one made as someone else, or what ssh-keygen said.
  """
  def sign_commit(%Task{} = task, payload) when is_binary(payload) do
    author = commit_author(task)

    with {:ok, key, public} <- key(author),
         {:ok, type, email} <- signer(payload),
         true <- email == author.email || {:error, :not_the_task_identity},
         :ok <- well_formed(type, payload) do
      sign(signing_key_file(task, key, public), payload)
    end
  end

  defp key(%{signing_key: key, signing_public_key: public}) when is_binary(key) and is_binary(public),
    do: {:ok, key, public}

  defp key(_unsigned), do: {:error, :no_signing_key}

  # The headers end at the first blank line; a continuation line, as a merge's mergetag has, starts with a space.
  defp signer(payload) do
    headers = payload |> String.split("\n\n", parts: 2) |> hd() |> String.split("\n")

    case headers do
      ["tree " <> _tree | rest] -> one(rest, "committer", "commit")
      ["object " <> _object | rest] -> one(rest, "tagger", "tag")
      _other -> {:error, :not_a_commit}
    end
  end

  defp one(headers, field, type) do
    case for(line <- headers, String.starts_with?(line, field <> " "), do: line) do
      [line] ->
        case Regex.run(~r/<([^<>]*)> \d+ [+-]\d{4}\z/, line) do
          [_whole, email] -> {:ok, type, email}
          nil -> {:error, :not_a_commit}
        end

      _none_or_several ->
        {:error, :not_a_commit}
    end
  end

  # git checks the object's whole format as it hashes it, which nothing is written by.
  defp well_formed(type, payload) do
    in_temp(payload, fn file ->
      case Tools.run("git", ["hash-object", "-t", type, "--no-filters", file], cd: Path.dirname(file)) do
        {_sha, 0} -> :ok
        {_refused, _code} -> {:error, :not_a_commit}
      end
    end)
  end

  defp sign(key_file, payload) do
    in_temp(payload, fn file ->
      case Tools.run("ssh-keygen", ["-Y", "sign", "-q", "-n", "git", "-f", key_file, file], stderr_to_stdout: true) do
        {_output, 0} -> {:ok, File.read!(file <> ".sig")}
        {output, _code} -> {:error, String.trim(output)}
      end
    end)
  end

  defp in_temp(payload, fun) do
    dir = Path.join(System.tmp_dir!(), "rail-sign-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    file = Path.join(dir, "payload")
    File.write!(file, payload)

    try do
      fun.(file)
    after
      File.rm_rf(dir)
    end
  end
end
