defmodule Rail.Git.Utils.SigningKeyFile do
  @moduledoc false

  alias Rail.Pipeline.Schemas.Task

  @doc """
  Writes `key`, a private key, to a file in `task`'s repository folder, with `public` beside it, and returns its path.
  No sandbox mounts that folder, so the key never leaves Rail; ssh-keygen signs with a file rather than an agent,
  since a machine's agent program, such as 1Password's, may know only its own keys.
  """
  def signing_key_file(%Task{} = task, key, public) when is_binary(key) and is_binary(public) do
    path = Path.join([Task.repo_path(task), "rail", "signing", "key"])
    File.mkdir_p!(Path.dirname(path))
    # Made unreadable before the key goes in, and moved over the last, so two at once never meet half a file.
    building = "#{path}.#{System.unique_integer([:positive])}"
    File.write!(building, "", [:exclusive])
    File.chmod!(building, 0o600)
    File.write!(building, key)
    File.rename!(building, path)
    File.write!(path <> ".pub", public)
    path
  end
end
