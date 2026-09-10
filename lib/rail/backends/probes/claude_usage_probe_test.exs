defmodule Rail.Backends.Probes.ClaudeUsageProbeTest do
  use Rail.DataCase, async: true

  alias Rail.Backends.Probes.ClaudeUsageProbe

  test "returns not_configured when executable does not pass validation" do
    result =
      ClaudeUsageProbe.probe(
        executable: "/invalid/bin/claude",
        path_validator: fn _path -> false end
      )

    assert %{
             backend: :claude,
             status: "not_configured",
             unavailable_reason: "Executable not found at '/invalid/bin/claude'"
           } = result
  end

  test "returns unavailable when auth status times out" do
    result =
      ClaudeUsageProbe.probe(
        executable: "/bin/claude",
        path_validator: fn _path -> true end,
        runner: fn _exe, _args, _opts -> {:error, :timeout} end
      )

    assert %{
             backend: :claude,
             status: "unavailable",
             unavailable_reason: "Auth status timed out after 20s"
           } = result
  end

  test "returns unavailable when auth status exits non-zero" do
    result =
      ClaudeUsageProbe.probe(
        executable: "/bin/claude",
        path_validator: fn _path -> true end,
        runner: fn _exe, _args, _opts -> {:ok, "error details", 1} end
      )

    assert %{
             backend: :claude,
             status: "unavailable",
             unavailable_reason: "Auth status exited with code 1"
           } = result
  end

  test "returns unavailable when auth status raises" do
    result =
      ClaudeUsageProbe.probe(
        executable: "/bin/claude",
        path_validator: fn _path -> true end,
        runner: fn _exe, _args, _opts -> {:error, :eacces} end
      )

    assert %{
             backend: :claude,
             status: "unavailable",
             unavailable_reason: "Failed to run auth status: :eacces"
           } = result
  end

  test "returns unavailable when auth status JSON is malformed" do
    result =
      ClaudeUsageProbe.probe(
        executable: "/bin/claude",
        path_validator: fn _path -> true end,
        runner: fn _exe, _args, _opts -> {:ok, "not json", 0} end
      )

    assert %{
             backend: :claude,
             status: "unavailable",
             unavailable_reason: reason
           } = result

    assert reason =~ "Failed to parse auth status JSON"
  end

  test "returns signed_out when auth status indicates logged out" do
    auth_json = ~s({"loggedIn":false,"email":"loggedout@example.com","subscriptionType":"Pro"})

    result =
      ClaudeUsageProbe.probe(
        executable: "/bin/claude",
        path_validator: fn _path -> true end,
        runner: fn _exe, _args, _opts -> {:ok, auth_json, 0} end
      )

    assert %{
             backend: :claude,
             status: "signed_out",
             account_label: "loggedout@example.com",
             unavailable_reason: "Not logged in"
           } = result
  end

  test "returns unavailable when config directory cannot be resolved" do
    auth_json = ~s({"loggedIn":true,"email":"alice@example.com","subscriptionType":"Pro"})

    # Provide a runner that handles auth status and refresh
    runner = fn _exe, args, _opts ->
      case args do
        ["auth", "status", "--json"] -> {:ok, auth_json, 0}
        ["-p", "/usage" | _rest] -> {:ok, "{}", 0}
      end
    end

    # Save and restore environment variables
    old_claude_dir = System.get_env("CLAUDE_CONFIG_DIR")
    old_home = System.get_env("HOME")
    System.delete_env("CLAUDE_CONFIG_DIR")
    System.delete_env("HOME")

    on_exit(fn ->
      if old_claude_dir, do: System.put_env("CLAUDE_CONFIG_DIR", old_claude_dir)
      if old_home, do: System.put_env("HOME", old_home)
    end)

    result =
      ClaudeUsageProbe.probe(
        executable: "/bin/claude",
        path_validator: fn _path -> true end,
        runner: runner,
        custom_config_path: nil
      )

    assert %{
             backend: :claude,
             status: "unavailable",
             unavailable_reason: "Could not determine user home or config directory"
           } = result
  end

  test "returns unavailable when config file fails to read" do
    auth_json = ~s({"loggedIn":true,"email":"alice@example.com","subscriptionType":"Pro"})

    runner = fn _exe, args, _opts ->
      case args do
        ["auth", "status", "--json"] -> {:ok, auth_json, 0}
        _other -> {:ok, "{}", 0}
      end
    end

    result =
      ClaudeUsageProbe.probe(
        executable: "/bin/claude",
        path_validator: fn _path -> true end,
        runner: runner,
        custom_config_path: "/non/existent/claude.json",
        config_file_reader: fn _path -> {:error, :enoent} end
      )

    assert %{
             backend: :claude,
             status: "unavailable",
             unavailable_reason: reason
           } = result

    assert reason =~ "Failed to read Claude config at '/non/existent/claude.json'"
  end

  test "returns unavailable when config JSON is invalid" do
    auth_json = ~s({"loggedIn":true,"email":"alice@example.com","subscriptionType":"Pro"})

    runner = fn _exe, args, _opts ->
      case args do
        ["auth", "status", "--json"] -> {:ok, auth_json, 0}
        _other -> {:ok, "{}", 0}
      end
    end

    result =
      ClaudeUsageProbe.probe(
        executable: "/bin/claude",
        path_validator: fn _path -> true end,
        runner: runner,
        custom_config_path: "/custom/claude.json",
        config_file_reader: fn _path -> {:ok, "not a json"} end
      )

    assert %{
             backend: :claude,
             status: "unavailable",
             unavailable_reason: reason
           } = result

    assert reason =~ "Failed to parse config file"
  end

  test "returns unavailable when cachedUsageUtilization is missing" do
    auth_json = ~s({"loggedIn":true,"email":"alice@example.com","subscriptionType":"Pro"})

    runner = fn _exe, args, _opts ->
      case args do
        ["auth", "status", "--json"] -> {:ok, auth_json, 0}
        _other -> {:ok, "{}", 0}
      end
    end

    result =
      ClaudeUsageProbe.probe(
        executable: "/bin/claude",
        path_validator: fn _path -> true end,
        runner: runner,
        custom_config_path: "/custom/claude.json",
        config_file_reader: fn _path -> {:ok, ~s({"otherKey": 123})} end
      )

    assert %{
             backend: :claude,
             status: "unavailable",
             unavailable_reason: "No cachedUsageUtilization found in config"
           } = result
  end

  test "successfully probes and parses quota usage with groups and windows" do
    auth_json = ~s({"loggedIn":true,"email":"engineer@example.com","subscriptionType":"enterprise"})

    config_json =
      ~s({"cachedUsageUtilization":{"fetchedAtMs":1725894000000,"utilization":{"limits":[{"group":"session","kind":"session","percent":20.0,"resets_at":"2026-09-10T12:00:00Z"},{"group":"weekly","kind":"weekly_all","scope":{"model":{"display_name":"Sonnet 3.7"}},"percent":35.5,"resets_at":"2026-09-15T12:00:00Z"}]}}})

    runner = fn _exe, args, _opts ->
      case args do
        ["auth", "status", "--json"] -> {:ok, auth_json, 0}
        ["-p", "/usage" | _rest] -> {:ok, ~s({"status": "ok"}), 0}
      end
    end

    result =
      ClaudeUsageProbe.probe(
        executable: "/bin/claude",
        path_validator: fn _path -> true end,
        runner: runner,
        custom_config_path: "/home/user/.claude.json",
        config_file_reader: fn _path -> {:ok, config_json} end
      )

    assert %{
             backend: :claude,
             status: "ready",
             account_label: "engineer@example.com",
             account_detail: "enterprise",
             groups: groups,
             fetched_at: %DateTime{},
             unavailable_reason: nil
           } = result

    assert [
             %{name: "Session", count: 1, details: %{"windows" => [session_win]}},
             %{name: "Weekly", count: 1, details: %{"windows" => [weekly_win]}}
           ] = groups

    assert session_win["label"] == "Session"
    assert session_win["remaining_percent"] == 80.0
    assert weekly_win["label"] == "Weekly · Sonnet 3.7"
    assert weekly_win["remaining_percent"] == 64.5
  end

  test "parse/3 pure function handles window label fallback variations" do
    auth_json = ~s({"loggedIn":true,"email":"alice@example.com","subscriptionType":"Pro"})

    custom_limits = [
      %{"group" => "session", "kind" => "session", "percent" => 10.0},
      %{"group" => "weekly", "kind" => "weekly_all", "percent" => 20.0},
      %{"group" => "custom", "kind" => "custom_window", "percent" => nil},
      %{"group" => "", "kind" => nil, "percent" => 50.0}
    ]

    config_json =
      Jason.encode!(%{
        "cachedUsageUtilization" => %{
          "fetchedAtMs" => nil,
          "utilization" => %{"limits" => custom_limits}
        }
      })

    result = ClaudeUsageProbe.parse("/bin/claude", auth_json, config_json)
    assert result.status == "ready"
    assert length(result.groups) == 4

    assert [
             %{name: "Session", details: %{"windows" => [%{"label" => "Session", "remaining_percent" => 90.0}]}},
             %{name: "Weekly", details: %{"windows" => [%{"label" => "Weekly (all models)"}]}},
             %{
               name: "Custom",
               details: %{
                 "windows" => [
                   %{"label" => "custom_window", "remaining_percent" => nil}
                 ]
               }
             },
             %{name: "General", details: %{"windows" => [%{"label" => "Window", "remaining_percent" => 50.0}]}}
           ] = result.groups
  end

  test "parse/3 handles malformed auth or config JSON" do
    assert %{status: "unavailable", unavailable_reason: reason} =
             ClaudeUsageProbe.parse("/bin/claude", "invalid auth", "{}")

    assert reason =~ "Failed to parse auth status JSON"

    valid_auth = ~s({"loggedIn":true,"email":"alice@example.com","subscriptionType":"Pro"})

    assert %{status: "unavailable", unavailable_reason: reason2} =
             ClaudeUsageProbe.parse("/bin/claude", valid_auth, "invalid config")

    assert reason2 =~ "Failed to parse config file"
  end

  test "resolves config path via CLAUDE_CONFIG_DIR and HOME environment variables" do
    auth_json = ~s({"loggedIn":true,"email":"alice@example.com","subscriptionType":"Pro"})

    config_json =
      ~s({"cachedUsageUtilization":{"fetchedAtMs":1725894000000,"utilization":{"limits":[{"group":"session","kind":"session","percent":20.0,"resets_at":"2026-09-10T12:00:00Z"},{"group":"weekly","kind":"weekly_all","scope":{"model":{"display_name":"Sonnet 3.7"}},"percent":35.5,"resets_at":"2026-09-15T12:00:00Z"}]}}})

    runner = fn _exe, args, _opts ->
      case args do
        ["auth", "status", "--json"] -> {:ok, auth_json, 0}
        _other -> {:ok, "{}", 0}
      end
    end

    # Test CLAUDE_CONFIG_DIR
    System.put_env("CLAUDE_CONFIG_DIR", "/tmp/claude_dir_test")

    on_exit(fn ->
      System.delete_env("CLAUDE_CONFIG_DIR")
    end)

    reader = fn path ->
      if path == "/tmp/claude_dir_test/.claude.json" do
        {:ok, config_json}
      else
        {:error, :enoent}
      end
    end

    result =
      ClaudeUsageProbe.probe(
        executable: "/bin/claude",
        path_validator: fn _path -> true end,
        runner: runner,
        config_file_reader: reader
      )

    assert result.status == "ready"
  end

  test "parse/3 returns signed_out when loggedIn is false" do
    auth_signed_out =
      Jason.encode!(%{"loggedIn" => false, "email" => "loggedout@example.com", "subscriptionType" => "pro"})

    result = ClaudeUsageProbe.parse("/bin/claude", auth_signed_out, "{}")
    assert result.status == "signed_out"
    assert result.account_label == "loggedout@example.com"
  end

  test "parse/3 merges multiple limits in the same group and handles nil group and non-list limits" do
    auth_json = ~s({"loggedIn":true,"email":"alice@example.com","subscriptionType":"Pro"})

    multi_limit_config =
      Jason.encode!(%{
        "cachedUsageUtilization" => %{
          "utilization" => %{
            "limits" => [
              %{"group" => "session", "window" => "5h", "percent" => 10.0},
              %{"group" => "session", "window" => "daily", "percent" => 20.0},
              %{"group" => nil, "window" => "weekly", "percent" => 30.0}
            ]
          }
        }
      })

    result = ClaudeUsageProbe.parse("/bin/claude", auth_json, multi_limit_config)
    assert [%{name: "Session", count: 2}, %{name: "General", count: 1}] = result.groups

    # Non-list limits
    non_list_config = Jason.encode!(%{"cachedUsageUtilization" => %{"utilization" => %{"limits" => "invalid"}}})
    result_non_list = ClaudeUsageProbe.parse("/bin/claude", auth_json, non_list_config)
    assert result_non_list.groups == []
  end

  test "probe/1 handles executable_path, default executable, and warm up runner exceptions" do
    # executable_path
    assert %{status: "not_configured"} =
             ClaudeUsageProbe.probe(
               executable_path: "/custom/bin/claude",
               path_validator: fn _path -> false end
             )

    # default executable discovery
    assert %{status: "not_configured"} =
             ClaudeUsageProbe.probe(path_validator: fn _path -> false end)

    # warm up runner exception
    raising_runner = fn _exe, args, _opts ->
      case args do
        ["auth", "status", "--json"] ->
          {:ok, ~s({"loggedIn":true,"email":"alice@example.com","subscriptionType":"Pro"}), 0}

        _usage ->
          raise "warm up error"
      end
    end

    result =
      ClaudeUsageProbe.probe(
        executable: "/bin/claude",
        path_validator: fn _path -> true end,
        runner: raising_runner,
        custom_config_path: "/dummy.json",
        config_file_reader: fn _path ->
          {:ok,
           ~s({"cachedUsageUtilization":{"fetchedAtMs":1725894000000,"utilization":{"limits":[{"group":"session","kind":"session","percent":20.0,"resets_at":"2026-09-10T12:00:00Z"},{"group":"weekly","kind":"weekly_all","scope":{"model":{"display_name":"Sonnet 3.7"}},"percent":35.5,"resets_at":"2026-09-15T12:00:00Z"}]}}})}
        end
      )

    assert result.status == "ready"
  end
end
