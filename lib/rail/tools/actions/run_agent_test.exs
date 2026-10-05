defmodule Rail.Tools.Actions.RunAgentTest do
  # Dispatch is switched off application-wide in one test, so nothing may run beside it.
  use Rail.DataCase, async: false

  alias Rail.Roles.Schemas.Role
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

    model = "claude-run-agent-#{System.unique_integer([:positive])}"
    role = %Role{name: "Triage", cli: :claude, model: model}

    %{backend: ready_backend(model, [], %{executable_path: script}), dir: dir, role: role, script: script}
  end

  test "runs the agent in the directory given, with the caller's env over the account's", %{
    backend: backend,
    dir: dir,
    role: role
  } do
    config_dir = Backend.config_dir(backend)

    assert {:ok, output} = Tools.run_agent(role, [], env: %{"RAIL_MCP_TOKEN" => "tok"}, cd: dir, timeout: 5_000)
    # `pwd` prints the physical path, which on macOS puts /private ahead of $TMPDIR.
    {physical_dir, 0} = System.cmd("pwd", ["-P"], cd: dir, env: %{})
    assert String.trim(output) == "#{config_dir}|tok|#{String.trim(physical_dir)}"

    assert {:ok, overridden} =
             Tools.run_agent(role, [], env: %{"CLAUDE_CONFIG_DIR" => "mine"}, cd: dir, timeout: 5_000)

    assert overridden =~ "mine|"
  end

  test "a non-zero exit, or no agent to run, is an error", %{backend: backend, dir: dir, role: role} do
    assert {:error, {:exit, 3}} = Tools.run_agent(role, ["fail"], cd: dir, timeout: 5_000)

    {:ok, _missing} = Tools.update_backend(system_scope(), backend, %{executable_path: Path.join(dir, "no-such-agent")})
    assert {:error, %ErlangError{original: :enoent}} = Tools.run_agent(role, [], cd: dir, timeout: 5_000)
  end

  test "an agent still running at the timeout is stopped", %{dir: dir, role: role} do
    assert {:error, :timeout} = Tools.run_agent(role, ["hang"], cd: dir, timeout: 100)
  end

  test "runs on the account a new conversation would, skipping one used up", %{
    backend: backend,
    dir: dir,
    role: role,
    script: script
  } do
    Repo.delete!(backend)
    in_a_day = DateTime.shift(DateTime.utc_now(), day: 1)
    _used_up = ready_backend(role.model, [{"Weekly", 0.0, in_a_day}], %{executable_path: script, label: "work"})
    roomy = ready_backend(role.model, [{"Weekly", 80.0, in_a_day}], %{executable_path: script, label: "personal"})

    assert {:ok, output} = Tools.run_agent(role, [], cd: dir, timeout: 5_000)
    assert output =~ Backend.config_dir(roomy)
  end

  test "waits for the earliest reset when every account is used up, and runs nothing", %{
    backend: backend,
    dir: dir,
    role: role,
    script: script
  } do
    soon = DateTime.utc_now() |> DateTime.shift(hour: 2) |> DateTime.truncate(:second)
    later = DateTime.utc_now() |> DateTime.shift(day: 3) |> DateTime.truncate(:second)
    Repo.delete!(backend)
    _first = ready_backend(role.model, [{"Weekly", 0.0, later}], %{executable_path: script})
    _second = ready_backend(role.model, [{"Session", 0.0, soon}], %{executable_path: script})

    reject(&Tools.run/3)
    assert {:error, {:waiting_for_usage, ^soon}} = Tools.run_agent(role, [], cd: dir, timeout: 5_000)
  end

  test "an account used up with no reset reported is looked at again after the next usage refresh", %{
    backend: backend,
    dir: dir,
    role: role
  } do
    Repo.delete!(backend)
    _spent = ready_backend(role.model, [{"Weekly", 0.0, nil}])

    assert {:error, {:waiting_for_usage, at}} = Tools.run_agent(role, [], cd: dir, timeout: 5_000)
    assert_in_delta DateTime.diff(at, DateTime.utc_now()), 5 * 60, 5
  end

  test "names the model when no signed-in account offers it", %{dir: dir, role: role} do
    _signed_out = ready_backend("claude-elsewhere", [], %{status: :signed_out})

    assert {:error, "No signed-in account offers claude-elsewhere. " <> _how} =
             Tools.run_agent(%{role | model: "claude-elsewhere"}, [], cd: dir, timeout: 5_000)
  end

  test "runs nothing while dispatch is off", %{dir: dir, role: role} do
    previous = Application.get_env(:rail, :no_dispatch)
    Application.put_env(:rail, :no_dispatch, true)
    on_exit(fn -> Application.put_env(:rail, :no_dispatch, previous) end)

    assert {:error, :dispatch_disabled} = Tools.run_agent(role, [], cd: dir, timeout: 5_000)
  end
end
