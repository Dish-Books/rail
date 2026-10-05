defmodule Rail.Tools.Utils.BackendEnv do
  @moduledoc false

  alias Rail.Tools.Schemas.Backend

  @doc """
  Returns the environment variables that point a backend's CLI at its own config
  directory, and so at the account signed in there. Claude's auto-memory is off,
  since what it learns belongs in Learnings, and it is signed in by the backend's
  token rather than by anything in the directory.
  """
  def backend_env(%Backend{} = backend) do
    env = %{Backend.env_var(:claude) => Backend.config_dir(backend), "CLAUDE_CODE_DISABLE_AUTO_MEMORY" => "1"}
    if backend.oauth_token, do: Map.put(env, "CLAUDE_CODE_OAUTH_TOKEN", backend.oauth_token), else: env
  end
end
