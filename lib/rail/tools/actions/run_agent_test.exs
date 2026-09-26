defmodule Rail.Tools.Actions.RunAgentTest do
  # Dispatch is switched off application-wide in one test, so nothing may run beside it.
  use Rail.DataCase, async: false

  alias Rail.Tools
  alias Rail.Tools.Schemas.Backend

  setup do
    dir = Path.join(System.tmp_dir!(), "run_agent_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    script = Path.join(dir, "agent")

    File.write!(script, ~S"""
    #!/bin/sh
    case "$1" in
      fail) echo "broke"; exit 3 ;;
      hang) sleep 5 ;;
      *) echo "$CLAUDE_CONFIG_DIR|$RAIL_MCP_TOKEN|$(pwd)" ;;
    esac
    """)

    File.chmod!(script, 0o755)

    %{backend: %Backend{id: "bkd_run_agent", name: :claude, executable_path: script}, dir: dir}
  end

  test "runs the agent in the directory given, with the caller's env over the backend's", %{
    backend: backend,
    dir: dir
  } do
    config_dir = Backend.config_dir(backend)

    assert {:ok, output} = Tools.run_agent(backend, [], env: %{"RAIL_MCP_TOKEN" => "tok"}, cd: dir, timeout: 5_000)
    assert String.trim(output) == "#{config_dir}|tok|#{dir}"

    assert {:ok, overridden} =
             Tools.run_agent(backend, [], env: %{"CLAUDE_CONFIG_DIR" => "mine"}, cd: dir, timeout: 5_000)

    assert overridden =~ "mine|"
  end

  test "a non-zero exit, or no agent to run, is an error", %{backend: backend, dir: dir} do
    assert {:error, {:exit, 3}} = Tools.run_agent(backend, ["fail"], cd: dir, timeout: 5_000)

    missing = %{backend | executable_path: Path.join(dir, "no-such-agent")}
    assert {:error, %ErlangError{original: :enoent}} = Tools.run_agent(missing, [], cd: dir, timeout: 5_000)
  end

  test "an agent still running at the timeout is stopped", %{backend: backend, dir: dir} do
    assert {:error, :timeout} = Tools.run_agent(backend, ["hang"], cd: dir, timeout: 100)
  end

  test "runs nothing while dispatch is off", %{backend: backend, dir: dir} do
    previous = Application.get_env(:rail, :no_dispatch)
    Application.put_env(:rail, :no_dispatch, true)
    on_exit(fn -> Application.put_env(:rail, :no_dispatch, previous) end)

    assert {:error, :dispatch_disabled} = Tools.run_agent(backend, [], cd: dir, timeout: 5_000)
  end
end
