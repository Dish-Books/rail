defmodule Rail.Tools.Utils.BackendEnv do
  @moduledoc false

  alias Rail.Tools.Schemas.Backend

  @doc """
  Returns the environment variables that point a backend's CLI at its own config
  directory, and so at the account signed in there. Empty for a CLI with no such
  variable.
  """
  def backend_env(%Backend{name: name} = backend) do
    case Backend.env_var(name) do
      var when is_binary(var) -> %{var => Backend.config_dir(backend)}
      nil -> %{}
    end
  end
end
