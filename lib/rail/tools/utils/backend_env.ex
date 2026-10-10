defmodule Rail.Tools.Utils.BackendEnv do
  @moduledoc false

  alias Rail.Tools.Schemas.Backend

  @bg_wait_ceiling to_timeout(hour: 1)

  @doc """
  Points a backend's CLI at its own config directory, and so its account, with Claude's auto-memory off for Learnings.
  Background subagents get 60 minutes after the lead goes idle, not Claude Code's 10, before they are stopped.
  """
  def backend_env(%Backend{} = backend) do
    %{
      Backend.env_var(:claude) => Backend.config_dir(backend),
      "CLAUDE_CODE_DISABLE_AUTO_MEMORY" => "1",
      "CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS" => Integer.to_string(@bg_wait_ceiling)
    }
  end
end
