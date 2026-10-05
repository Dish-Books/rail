defmodule Rail.Tools.Utils.BackendEnv do
  @moduledoc false

  alias Rail.Tools.Schemas.Backend

  @doc """
  Returns the environment variables that point a backend's CLI at its own config
  directory, and so at the account signed in there. Claude's auto-memory is off,
  since what it learns belongs in Learnings.
  """
  def backend_env(%Backend{} = backend) do
    %{Backend.env_var(:claude) => Backend.config_dir(backend), "CLAUDE_CODE_DISABLE_AUTO_MEMORY" => "1"}
  end
end
