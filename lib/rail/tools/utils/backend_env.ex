defmodule Rail.Tools.Utils.BackendEnv do
  @moduledoc false

  alias Rail.Tools.Schemas.Backend

  @doc """
  Points a backend's CLI at its own config directory, and so its account, with Claude's auto-memory off for Learnings.
  Background tasks are off: the CLI waits on one after the turn, so a server or subagent left running held a run open.
  """
  def backend_env(%Backend{} = backend) do
    %{
      Backend.env_var(:claude) => Backend.config_dir(backend),
      "CLAUDE_CODE_DISABLE_AUTO_MEMORY" => "1",
      "CLAUDE_CODE_DISABLE_BACKGROUND_TASKS" => "1"
    }
  end
end
