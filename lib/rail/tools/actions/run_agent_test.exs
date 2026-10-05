defmodule Rail.Tools.Actions.RunAgentTest do
  # Dispatch is switched off application-wide in one test, so nothing may run beside it.
  use Rail.DataCase, async: false

  alias Rail.Repo
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
      refused) echo '{"type":"result","is_error":true,"error":"authentication_failed","result":"Invalid bearer token"}'; exit 1 ;;
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
    # `pwd` prints the physical path, which on macOS puts /private ahead of $TMPDIR.
    {physical_dir, 0} = System.cmd("pwd", ["-P"], cd: dir, env: %{})
    assert String.trim(output) == "#{config_dir}|tok|#{String.trim(physical_dir)}"

    assert {:ok, overridden} =
             Tools.run_agent(backend, [], env: %{"CLAUDE_CONFIG_DIR" => "mine"}, cd: dir, timeout: 5_000)

    assert overridden =~ "mine|"
  end

  test "a non-zero exit, or no agent to run, is an error", %{backend: backend, dir: dir} do
    assert {:error, {:exit, 3, "broke\n"}} = Tools.run_agent(backend, ["fail"], cd: dir, timeout: 5_000)

    missing = %{backend | executable_path: Path.join(dir, "no-such-agent")}
    assert {:error, %ErlangError{original: :enoent}} = Tools.run_agent(missing, [], cd: dir, timeout: 5_000)
  end

  test "runs nothing on a backend that is signed out", %{backend: backend, dir: dir} do
    reject(&Tools.run/3)

    assert {:error, :backend_signed_out} =
             Tools.run_agent(%{backend | status: :signed_out}, [], cd: dir, timeout: 5_000)
  end

  test "a token Claude refuses signs the backend out once, so nothing more is started on it", %{
    backend: %Backend{executable_path: script},
    dir: dir
  } do
    scope = system_scope()
    {:ok, backend} = Tools.create_backend(scope, %{name: :claude, executable_path: script})
    {:ok, backend} = Tools.set_backend_token(scope, backend, "tok")

    assert {:error, {:exit, 1, output}} = Tools.run_agent(backend, ["refused"], cd: dir, timeout: 5_000)
    assert Tools.agent_failure_reason(output) =~ "Invalid bearer token. Sign the backend in again"

    assert %Backend{status: :signed_out, session_lost_at: %DateTime{} = lost_at, unavailable_reason: reason} =
             Repo.get!(Backend, backend.id)

    assert reason =~ "Claude rejected the token."

    # A pass that started before the refusal was recorded changes nothing when it is refused too.
    assert {:error, {:exit, 1, _output}} = Tools.run_agent(backend, ["refused"], cd: dir, timeout: 5_000)
    assert %Backend{session_lost_at: ^lost_at} = Repo.get!(Backend, backend.id)
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
