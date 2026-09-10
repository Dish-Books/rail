defmodule Rail.Backends.RefreshServerTest do
  use Rail.DataCase, async: true

  alias Ecto.Adapters.SQL.Sandbox
  alias Rail.Backends.RefreshServer
  alias Rail.Backends.Schemas.CliAccount

  setup do
    {:ok, pid} =
      RefreshServer.start_link(
        name: nil,
        interval: 0,
        claude_opts: [path_validator: fn _path -> false end],
        agy_opts: [path_validator: fn _path -> false end]
      )

    # The server refreshes in its own task, so lend it this test's DB connection.
    Sandbox.allow(Rail.Repo, self(), pid)

    on_exit(fn ->
      try do
        GenServer.stop(pid)
      catch
        :exit, _err -> :ok
      end
    end)

    %{server: pid, pid: pid}
  end

  test "running?/1 detects server liveness", %{server: server, pid: pid} do
    assert RefreshServer.running?(server)
    refute RefreshServer.running?(:definitely_not_running_server)

    GenServer.stop(pid)
    refute RefreshServer.running?(server)
  end

  test "start_link/1 supports named servers" do
    {:ok, named_pid} =
      RefreshServer.start_link(
        name: :named_refresh_server_test,
        interval: 0,
        claude_opts: [path_validator: fn _path -> false end],
        agy_opts: [path_validator: fn _path -> false end]
      )

    # The server refreshes in its own task, so lend it this test's DB connection.
    Sandbox.allow(Rail.Repo, self(), named_pid)

    assert Process.alive?(named_pid)
    assert RefreshServer.running?(:named_refresh_server_test)
    GenServer.stop(named_pid)
  end

  test "single-flights concurrent refresh requests to execute probes once", %{server: server} do
    test_node = "single-flight-node-#{System.unique_integer([:positive])}"
    caller = self()

    runner = fn exe, args, _run_opts ->
      send(caller, {:probe_executed, exe, args})
      # Small delay so concurrent callers overlap
      Process.sleep(40)

      case exe do
        "claude" ->
          auth = ~s({"loggedIn":true,"email":"alice@example.com","subscriptionType":"Pro"})
          {:ok, auth, 0}

        _agy ->
          usage =
            ~s({"status":"SUCCESS","command":{"data":{"groups":[{"name":"Gemini Models","buckets":[{"window":"5h","remaining_fraction":0.85,"reset_time":"2026-09-09T20:00:00Z"},{"window":"weekly","remaining_fraction":0.6,"reset_time":"2026-09-16T20:00:00Z"}]}]}}})

          {:ok, usage, 0}
      end
    end

    refresh_opts = [
      node: test_node,
      claude_opts: [
        executable: "claude",
        path_validator: fn _path -> true end,
        runner: runner,
        custom_config_path: "/test/claude.json",
        config_file_reader: fn _path ->
          {:ok,
           ~s({"cachedUsageUtilization":{"fetchedAtMs":1725894000000,"utilization":{"limits":[{"group":"session","kind":"session","percent":20.0,"resets_at":"2026-09-10T12:00:00Z"},{"group":"weekly","kind":"weekly_all","scope":{"model":{"display_name":"Sonnet 3.7"}},"percent":35.5,"resets_at":"2026-09-15T12:00:00Z"}]}}})}
        end
      ],
      agy_opts: [
        executable: "agy",
        path_validator: fn _path -> true end,
        runner: runner,
        file_reader: fn _path ->
          {:ok, ~s(2026-09-09T15:00:00.123Z INFO [Auth] applyAuthResult: email=alice@example.com, authMethod=oauth\n)}
        end
      ]
    ]

    # Spawn 3 concurrent tasks calling refresh
    task1 = Task.async(fn -> RefreshServer.refresh(server, refresh_opts) end)
    task2 = Task.async(fn -> RefreshServer.refresh(server, refresh_opts) end)
    task3 = Task.async(fn -> RefreshServer.refresh(server, refresh_opts) end)

    res1 = Task.await(task1)
    res2 = Task.await(task2)
    res3 = Task.await(task3)

    assert {:ok, [%CliAccount{backend: :claude}, %CliAccount{backend: :agy}]} = res1
    assert res1 == res2
    assert res2 == res3

    # Ensure probes were only executed once for each backend
    assert_receive {:probe_executed, "claude", ["auth", "status", "--json"]}
    assert_receive {:probe_executed, "agy", ["-p", "/usage", "--output-format", "json" | _rest]}
    refute_receive {:probe_executed, "claude", ["auth", "status", "--json"]}
    refute_receive {:probe_executed, "agy", ["-p", "/usage", "--output-format", "json" | _rest]}
  end

  test "periodic_tick triggers background execution without crashing" do
    claude_probe = [
      executable: "claude",
      path_validator: fn _path -> false end
    ]

    agy_probe = [
      executable: "agy",
      path_validator: fn _path -> false end
    ]

    {:ok, pid} =
      RefreshServer.start_link(
        name: nil,
        interval: 20,
        claude_opts: claude_probe,
        agy_opts: agy_probe
      )

    # The server refreshes in its own task, so lend it this test's DB connection.

    Sandbox.allow(Rail.Repo, self(), pid)

    # Let the interval tick once
    Process.sleep(50)
    assert Process.alive?(pid)

    try do
      GenServer.stop(pid)
    catch
      :exit, _err -> :ok
    end
  end

  test "propagates task error when probe crashes", %{server: server} do
    crash_opts = [
      claude_opts: [
        executable: "claude",
        path_validator: fn _path -> raise "unexpected probe explosion" end
      ],
      agy_opts: [
        executable: "agy",
        path_validator: fn _path -> false end
      ]
    ]

    assert {:error, {%RuntimeError{message: "unexpected probe explosion"}, _stack}} =
             RefreshServer.refresh(server, crash_opts)
  end

  test "periodic_tick is ignored when task is already in flight", %{server: server} do
    test_node = "in-flight-node-#{System.unique_integer([:positive])}"
    caller = self()

    runner = fn exe, _args, _opts ->
      send(caller, {:probe_started, exe})
      Process.sleep(80)

      {:ok,
       ~s({"status":"SUCCESS","command":{"data":{"groups":[{"name":"Gemini Models","buckets":[{"window":"5h","remaining_fraction":0.85,"reset_time":"2026-09-09T20:00:00Z"},{"window":"weekly","remaining_fraction":0.6,"reset_time":"2026-09-16T20:00:00Z"}]}]}}}),
       0}
    end

    refresh_opts = [
      node: test_node,
      claude_opts: [path_validator: fn _path -> false end],
      agy_opts: [
        executable: "agy",
        path_validator: fn _path -> true end,
        runner: runner,
        file_reader: fn _path ->
          {:ok, ~s(2026-09-09T15:00:00.123Z INFO [Auth] applyAuthResult: email=alice@example.com, authMethod=oauth\n)}
        end
      ]
    ]

    task = Task.async(fn -> RefreshServer.refresh(server, refresh_opts) end)
    assert_receive {:probe_started, "agy"}, 1000

    # Task is now actively in flight
    send(server, :periodic_tick)

    assert {:ok, [_claude, _agy]} = Task.await(task)
  end
end
