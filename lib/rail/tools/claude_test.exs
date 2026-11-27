defmodule Rail.Tools.ClaudeTest do
  use Rail.DataCase, async: true

  alias Rail.Tools
  alias Rail.Tools.Claude
  alias Rail.Tools.Schemas.Backend

  @auth_ok ~s({"loggedIn":true,"email":"alice@example.com","subscriptionType":"Pro"})

  setup do
    # A real executable, so the path check is the real one; what it would have
    # run is what gets stubbed.
    %{backend: %Backend{id: "bkd_claude_probe", name: :claude, executable_path: System.find_executable("sh")}}
  end

  test "reports not_configured unless the path is a runnable file" do
    assert %{status: :not_configured, unavailable_reason: "Executable not found at ''"} =
             Claude.probe(%Backend{name: :claude})

    missing = %Backend{name: :claude, executable_path: "/non/existent/claude"}

    assert %{
             name: :claude,
             status: :not_configured,
             unavailable_reason: "Executable not found at '/non/existent/claude'"
           } = Claude.probe(missing)

    assert %{status: :not_configured} = Claude.probe(%Backend{name: :claude, executable_path: System.tmp_dir!()})

    not_executable = Path.join(System.tmp_dir!(), "claude_probe_#{System.unique_integer([:positive])}")
    File.write!(not_executable, "#!/bin/sh\n")
    File.chmod!(not_executable, 0o644)
    on_exit(fn -> File.rm(not_executable) end)

    assert %{status: :not_configured} = Claude.probe(%Backend{name: :claude, executable_path: not_executable})
  end

  test "reports unavailable when auth status times out, fails to spawn, or exits non-zero", %{backend: backend} do
    stub(Tools, :run, fn _exe, _args, _opts -> {:error, :timeout} end)
    assert %{status: :unavailable, unavailable_reason: "Auth status timed out after 20s"} = Claude.probe(backend)

    stub(Tools, :run, fn _exe, _args, _opts -> {:error, :eacces} end)
    assert %{status: :unavailable, unavailable_reason: "Failed to run auth status: :eacces"} = Claude.probe(backend)

    stub(Tools, :run, fn _exe, _args, _opts -> {"error details", 1} end)
    assert %{status: :unavailable, unavailable_reason: "Auth status exited with code 1"} = Claude.probe(backend)
  end

  test "reports unavailable when auth status is not JSON", %{backend: backend} do
    stub(Tools, :run, fn _exe, _args, _opts -> {"not json", 0} end)

    assert %{status: :unavailable, unavailable_reason: reason} = Claude.probe(backend)
    assert reason =~ "Failed to parse auth status JSON"
  end

  test "reports signed_out when the CLI says it is not logged in", %{backend: backend} do
    signed_out = ~s({"loggedIn":false,"email":"bob@example.com","subscriptionType":"Free"})
    stub(Tools, :run, fn _exe, _args, _opts -> {signed_out, 0} end)

    assert %{
             status: :signed_out,
             account_label: "bob@example.com",
             account_detail: "Free",
             unavailable_reason: "Not logged in",
             usage: []
           } = Claude.probe(backend)
  end

  test "warms the usage cache before reading the config, and survives that raising", %{
    backend: %Backend{executable_path: executable} = backend
  } do
    test_pid = self()

    stub(Tools, :run, fn _exe, args, _opts ->
      case args do
        ["auth", "status", "--json"] ->
          {@auth_ok, 0}

        usage ->
          send(test_pid, {:warmed, usage})
          {"{}", 0}
      end
    end)

    stub(File, :read, fn _path -> {:ok, ~s({"cachedUsageUtilization":{}})} end)

    assert %{status: :ready} = Claude.probe(backend)
    # Run with no stdin, so the CLI does not sit waiting for input first.
    assert_received {:warmed,
                     [
                       "-c",
                       ~s(exec "$0" "$@" </dev/null),
                       ^executable,
                       "-p",
                       "/usage",
                       "--output-format",
                       "json",
                       "--strict-mcp-config"
                     ]}

    # A warm up that blows up must not take the probe down with it.
    stub(Tools, :run, fn _exe, args, _opts ->
      case args do
        ["auth", "status", "--json"] -> {@auth_ok, 0}
        _usage -> raise "warm up exploded"
      end
    end)

    assert %{status: :ready, account_label: "alice@example.com"} = Claude.probe(backend)
  end

  test "reports unavailable when the config cannot be read or parsed", %{backend: backend} do
    stub(Tools, :run, fn _exe, _args, _opts -> {@auth_ok, 0} end)

    stub(File, :read, fn _path -> {:error, :enoent} end)
    assert %{status: :unavailable, unavailable_reason: unreadable} = Claude.probe(backend)
    assert unreadable =~ "Failed to read Claude config at"

    stub(File, :read, fn _path -> {:ok, "invalid config"} end)
    assert %{status: :unavailable, unavailable_reason: unparsable} = Claude.probe(backend)
    assert unparsable =~ "Failed to parse config file"

    stub(File, :read, fn _path -> {:ok, ~s({"other":"key"})} end)

    assert %{
             status: :unavailable,
             unavailable_reason: "No cachedUsageUtilization found in config",
             account_label: "alice@example.com",
             account_detail: "Pro"
           } = Claude.probe(backend)
  end

  test "asks the account in the backend's config directory, and reads its config there", %{backend: backend} do
    config_dir = Backend.config_dir(backend)
    config_path = Path.join(config_dir, ".claude.json")
    test_pid = self()

    stub(Tools, :run, fn _exe, args, opts ->
      send(test_pid, {:ran, args, opts[:env]})
      {@auth_ok, 0}
    end)

    stub(File, :read, fn path ->
      send(test_pid, {:read, path})
      {:ok, "{}"}
    end)

    Claude.probe(backend)

    assert_received {:ran, ["auth", "status", "--json"], %{"CLAUDE_CONFIG_DIR" => ^config_dir}}

    assert_received {:ran, ["-c", _script, _claude, "-p", "/usage", "--output-format", "json", "--strict-mcp-config"],
                     %{"CLAUDE_CONFIG_DIR" => ^config_dir}}

    assert_received {:read, ^config_path}
  end

  test "reports ready with the cached usage grouped and labelled", %{backend: backend} do
    config =
      ~s({"cachedUsageUtilization":{"fetchedAtMs":1725894000000,"utilization":{"limits":[) <>
        ~s({"group":"session","kind":"session","percent":20.0,"resets_at":"2026-09-10T12:00:00Z"},) <>
        ~s({"group":"weekly","kind":"weekly_all","percent":35.5,"resets_at":"2026-09-15T12:00:00Z"},) <>
        ~s({"group":"weekly","scope":{"model":{"display_name":"Sonnet 3.7"}},"percent":10.0},) <>
        ~s({"group":"opus","kind":"","percent":null},{"group":null,"kind":"custom_kind","percent":5.0},) <>
        ~s({"group":"","kind":"weekly_all","percent":1.0}) <>
        ~s(]}}})

    stub(Tools, :run, fn _exe, _args, _opts -> {@auth_ok, 0} end)
    stub(File, :read, fn _path -> {:ok, config} end)

    fetched_at = DateTime.from_unix!(1_725_894_000_000, :millisecond)

    assert %{
             name: :claude,
             status: :ready,
             account_label: "alice@example.com",
             account_detail: "Pro",
             unavailable_reason: nil,
             fetched_at: ^fetched_at,
             usage: [session, weekly, opus, general]
           } = Claude.probe(backend)

    assert %{
             name: "Session",
             count: 1,
             details: %{"windows" => [%{"label" => "Session", "remaining_percent" => 80.0}]}
           } = session

    assert %{name: "Weekly", count: 2, details: %{"windows" => weekly_windows}} = weekly
    assert [%{"label" => "Weekly"}, %{"label" => "Weekly · Sonnet 3.7"}] = weekly_windows

    assert %{name: "Opus", details: %{"windows" => [%{"label" => "Window", "remaining_percent" => nil}]}} = opus
    assert %{name: "General", count: 2, details: %{"windows" => general_windows}} = general
    assert [%{"label" => "custom_kind"}, %{"label" => "Weekly"}] = general_windows
  end

  test "falls back to now when the config records no fetch time and limits are not a list", %{backend: backend} do
    stub(Tools, :run, fn _exe, _args, _opts -> {@auth_ok, 0} end)
    stub(File, :read, fn _path -> {:ok, ~s({"cachedUsageUtilization":{"utilization":{"limits":"nope"}}})} end)

    before = DateTime.utc_now()
    assert %{status: :ready, usage: [], fetched_at: fetched_at} = Claude.probe(backend)
    assert DateTime.compare(fetched_at, before) in [:eq, :gt]
  end

  describe "access_token/1" do
    setup do
      backend = %Backend{
        id: "bkd_token_#{System.unique_integer([:positive])}",
        name: :claude,
        executable_path: System.find_executable("sh")
      }

      File.mkdir_p!(Backend.config_dir(backend))
      on_exit(fn -> File.rm_rf(Backend.config_dir(backend)) end)
      %{backend: backend}
    end

    test "is the login's token while it has time left", %{backend: backend} do
      claude_login(backend, "fresh", System.system_time(:millisecond) + 3_600_000)
      reject(Tools, :run, 3)
      assert {:ok, "fresh"} = Claude.access_token(backend)

      claude_login(backend, "forever", nil)
      assert {:ok, "forever"} = Claude.access_token(backend)
    end

    test "is refreshed by asking the CLI something when about to expire", %{backend: backend} do
      claude_login(backend, "stale", System.system_time(:millisecond) + 1_000)

      expect(Tools, :run, fn "/bin/sh", ["-c", _without_stdin, _executable, "-p", "/usage" | _rest], opts ->
        assert opts[:env]["CLAUDE_CONFIG_DIR"] == Backend.config_dir(backend)
        claude_login(backend, "renewed", System.system_time(:millisecond) + 3_600_000)
        {"", 0}
      end)

      assert {:ok, "renewed"} = Claude.access_token(backend)
    end

    test "a refusal is answered by the token another caller refreshed meanwhile, or by refreshing", %{backend: backend} do
      claude_login(backend, "newer", nil)
      assert {:ok, "newer"} = Claude.refresh_access_token(backend, "refused")

      expect(Tools, :run, fn _sh, _args, _opts -> raise "the CLI crashed" end)
      assert {:ok, "newer"} = Claude.refresh_access_token(backend, "newer")

      # A refresh that signs the account out leaves no login to read.
      expect(Tools, :run, fn _sh, _args, _opts ->
        File.rm!(Path.join(Backend.config_dir(backend), ".credentials.json"))
      end)

      assert {:error, :signed_out} = Claude.refresh_access_token(backend, "newer")

      File.write!(Path.join(Backend.config_dir(backend), ".credentials.json"), ~s({"claudeAiOauth":{}}))
      expect(Tools, :run, fn _sh, _args, _opts -> {"", 0} end)
      assert {:error, :signed_out} = Claude.refresh_access_token(backend, "newer")
    end

    test "is no token without a login, or with one that cannot be read", %{backend: backend} do
      assert {:error, :signed_out} = Claude.access_token(backend)

      path = Path.join(Backend.config_dir(backend), ".credentials.json")
      File.write!(path, ~s({"other":{}}))
      assert {:error, :signed_out} = Claude.access_token(backend)

      File.write!(path, "[]")
      assert {:error, :signed_out} = Claude.access_token(backend)

      File.write!(path, "not json")
      assert {:error, %Jason.DecodeError{}} = Claude.access_token(backend)

      assert {:error, %Jason.DecodeError{}} = Claude.refresh_access_token(backend, "unreadable")

      File.rm!(path)
      assert {:error, :signed_out} = Claude.refresh_access_token(backend, "gone")
    end
  end
end
