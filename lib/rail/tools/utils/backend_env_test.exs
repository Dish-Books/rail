defmodule Rail.Tools.Utils.BackendEnvTest do
  use ExUnit.Case, async: true

  import Rail.Tools.Utils.BackendEnv

  alias Rail.Tools.Schemas.Backend

  test "points Claude at the backend's own config directory, with its auto-memory and background tasks off" do
    claude = %Backend{id: "bkd_claude", name: :claude}

    assert backend_env(claude) == %{
             "CLAUDE_CONFIG_DIR" => Backend.config_dir(claude),
             "CLAUDE_CODE_DISABLE_AUTO_MEMORY" => "1",
             "CLAUDE_CODE_DISABLE_BACKGROUND_TASKS" => "1"
           }
  end
end
