defmodule Rail.Tools.Utils.BackendEnvTest do
  use ExUnit.Case, async: true

  import Rail.Tools.Utils.BackendEnv

  alias Rail.Tools.Schemas.Backend

  test "points each CLI at the backend's own config directory through its own variable" do
    codex = %Backend{id: "bkd_codex", name: :codex}

    assert backend_env(codex) == %{"CODEX_HOME" => Backend.config_dir(codex)}
  end

  test "Claude also has its auto-memory off, so nothing it learns is kept out of sight" do
    claude = %Backend{id: "bkd_claude", name: :claude}

    assert backend_env(claude) == %{
             "CLAUDE_CONFIG_DIR" => Backend.config_dir(claude),
             "CLAUDE_CODE_DISABLE_AUTO_MEMORY" => "1"
           }
  end

  test "leaves the environment alone for a CLI without a config directory variable" do
    assert backend_env(%Backend{id: "bkd_agy", name: :agy}) == %{}
  end
end
