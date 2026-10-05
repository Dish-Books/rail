defmodule Rail.Tools.Utils.BackendEnvTest do
  use ExUnit.Case, async: true

  import Rail.Tools.Utils.BackendEnv

  alias Rail.Tools.Schemas.Backend

  test "points Claude at the backend's own config directory, with its auto-memory off" do
    claude = %Backend{id: "bkd_claude", name: :claude}

    assert backend_env(claude) == %{
             "CLAUDE_CONFIG_DIR" => Backend.config_dir(claude),
             "CLAUDE_CODE_DISABLE_AUTO_MEMORY" => "1"
           }
  end

  test "Claude is signed in by the backend's token, when it has one" do
    claude = %Backend{id: "bkd_claude", name: :claude, oauth_token: "sk-ant-oat01-abc"}

    assert %{"CLAUDE_CODE_OAUTH_TOKEN" => "sk-ant-oat01-abc", "CLAUDE_CONFIG_DIR" => _dir} = backend_env(claude)
  end
end
