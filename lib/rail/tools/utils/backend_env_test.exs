defmodule Rail.Tools.Utils.BackendEnvTest do
  use ExUnit.Case, async: true

  import Rail.Tools.Utils.BackendEnv

  alias Rail.Tools.Schemas.Backend

  test "points each CLI at the backend's own config directory through its own variable" do
    claude = %Backend{id: "bkd_claude", name: :claude}
    codex = %Backend{id: "bkd_codex", name: :codex}

    assert backend_env(claude) == %{"CLAUDE_CONFIG_DIR" => Backend.config_dir(claude)}
    assert backend_env(codex) == %{"CODEX_HOME" => Backend.config_dir(codex)}
  end

  test "leaves the environment alone for a CLI without a config directory variable" do
    assert backend_env(%Backend{id: "bkd_agy", name: :agy}) == %{}
  end
end
