defmodule Rail.Backends.Probes.AgyUsageProbeTest do
  use Rail.DataCase, async: true

  import RailTest.BackendsHelpers

  alias Rail.Backends.Probes.AgyUsageProbe

  test "returns not_configured when executable does not pass validation" do
    result =
      AgyUsageProbe.probe(
        executable: "/invalid/bin/agy",
        path_validator: fn _path -> false end
      )

    assert %{
             backend: :agy,
             status: "not_configured",
             unavailable_reason: "Executable not found at '/invalid/bin/agy'"
           } = result
  end

  test "returns unavailable when probe execution times out" do
    result =
      AgyUsageProbe.probe(
        executable: "/bin/agy",
        path_validator: fn _path -> true end,
        runner: fn _exe, _args, _opts -> {:error, :timeout} end
      )

    assert %{
             backend: :agy,
             status: "unavailable",
             unavailable_reason: "Usage check timed out after 20s"
           } = result
  end

  test "returns unavailable when probe execution raises" do
    result =
      AgyUsageProbe.probe(
        executable: "/bin/agy",
        path_validator: fn _path -> true end,
        runner: fn _exe, _args, _opts -> {:error, :enoent} end
      )

    assert %{
             backend: :agy,
             status: "unavailable",
             unavailable_reason: "Failed to execute probe: :enoent"
           } = result
  end

  test "returns signed_out when CLI exits non-zero with NOT_LOGGED_IN" do
    result =
      AgyUsageProbe.probe(
        executable: "/bin/agy",
        path_validator: fn _path -> true end,
        runner: fn _exe, _args, _opts -> {:ok, "Error: NOT_LOGGED_IN to service", 1} end
      )

    assert %{
             backend: :agy,
             status: "signed_out",
             unavailable_reason: "CLI exited with code 1"
           } = result
  end

  test "returns unavailable when CLI exits non-zero without NOT_LOGGED_IN" do
    result =
      AgyUsageProbe.probe(
        executable: "/bin/agy",
        path_validator: fn _path -> true end,
        runner: fn _exe, _args, _opts -> {:ok, "Internal command failure", 2} end
      )

    assert %{
             backend: :agy,
             status: "unavailable",
             unavailable_reason: "CLI exited with code 2"
           } = result
  end

  test "returns unavailable when usage stdout is invalid JSON" do
    result =
      AgyUsageProbe.probe(
        executable: "/bin/agy",
        path_validator: fn _path -> true end,
        runner: fn _exe, _args, _opts -> {:ok, "not json", 0} end
      )

    assert %{
             backend: :agy,
             status: "unavailable",
             unavailable_reason: reason
           } = result

    assert reason =~ "Failed to parse usage JSON"
  end

  test "handles non-SUCCESS status in usage JSON" do
    logged_out_json = Jason.encode!(%{"status" => "NOT_LOGGED_IN", "response" => "Please login"})

    result1 =
      AgyUsageProbe.probe(
        executable: "/bin/agy",
        path_validator: fn _path -> true end,
        runner: fn _exe, _args, _opts -> {:ok, logged_out_json, 0} end
      )

    assert %{
             backend: :agy,
             status: "signed_out",
             unavailable_reason: "Please login"
           } = result1

    login_prompt_json = Jason.encode!(%{"status" => "ERROR", "response" => "You need to log in first"})

    result2 =
      AgyUsageProbe.probe(
        executable: "/bin/agy",
        path_validator: fn _path -> true end,
        runner: fn _exe, _args, _opts -> {:ok, login_prompt_json, 0} end
      )

    assert %{
             backend: :agy,
             status: "signed_out",
             unavailable_reason: "You need to log in first"
           } = result2

    generic_error_json = Jason.encode!(%{"status" => "RATE_LIMIT", "response" => ""})

    result3 =
      AgyUsageProbe.probe(
        executable: "/bin/agy",
        path_validator: fn _path -> true end,
        runner: fn _exe, _args, _opts -> {:ok, generic_error_json, 0} end
      )

    assert %{
             backend: :agy,
             status: "unavailable",
             unavailable_reason: "RATE_LIMIT"
           } = result3
  end

  test "successfully probes usage, scrapes identity from scratch log, and cleans up temp dir" do
    usage_json = sample_agy_usage_json()
    log_data = sample_agy_scratch_log("dev@google.com", "browser_oauth")

    temp_dir = Path.join(System.tmp_dir!(), "agy_test_dir_#{System.unique_integer([:positive])}")

    runner = fn _exe, _args, opts ->
      scratch_log = Path.join(opts[:cd], "agy_scratch.log")
      File.write!(scratch_log, log_data)
      {:ok, usage_json, 0}
    end

    fixed_time = ~U[2026-09-09 15:30:00Z]

    result =
      AgyUsageProbe.probe(
        executable: "/bin/agy",
        path_validator: fn _path -> true end,
        runner: runner,
        temp_dir: temp_dir,
        fetched_at: fixed_time
      )

    assert %{
             backend: :agy,
             status: "ready",
             account_label: "dev@google.com",
             account_detail: "browser_oauth",
             groups: [
               %{
                 name: "Gemini Models",
                 count: 2,
                 details: %{
                   "windows" => [
                     %{"label" => "5-Hour", "remaining_percent" => 85.0},
                     %{"label" => "Weekly", "remaining_percent" => 60.0}
                   ]
                 }
               }
             ],
             fetched_at: ^fixed_time,
             unavailable_reason: nil
           } = result

    # Ensure temp dir and scratch log were cleaned up
    refute File.exists?(Path.join(temp_dir, "agy_scratch.log"))
    refute File.exists?(temp_dir)
  end

  test "parse/2 handles diverse bucket window and identity formats" do
    custom_groups = [
      %{
        "name" => "",
        "buckets" => [
          %{"window" => "5h", "remaining_fraction" => 1.0},
          %{"window" => "weekly", "remaining_fraction" => 0.5},
          %{"window" => "daily", "name" => "Custom Daily", "remaining_fraction" => nil},
          %{"window" => "monthly", "name" => "", "remaining_fraction" => 0.2},
          %{"window" => "", "name" => "", "remaining_fraction" => 0.1}
        ]
      }
    ]

    usage_json =
      Jason.encode!(%{
        "status" => "SUCCESS",
        "command" => %{
          "data" => %{
            "groups" => custom_groups
          }
        }
      })

    # Empty log file
    result_empty_log =
      AgyUsageProbe.parse("/bin/agy", usage_stdout: usage_json, log_content: "")

    assert result_empty_log.account_label == "Account unknown"
    assert result_empty_log.account_detail == nil
    assert [%{name: "Limits", details: %{"windows" => windows}}] = result_empty_log.groups

    assert [
             %{"label" => "5-Hour", "remaining_percent" => 100.0},
             %{"label" => "Weekly", "remaining_percent" => 50.0},
             %{"label" => "Custom Daily", "remaining_percent" => nil},
             %{"label" => "monthly", "remaining_percent" => 20.0},
             %{"label" => "Limit", "remaining_percent" => 10.0}
           ] = windows

    # Log with empty email
    log_empty_email = "applyAuthResult: email= , authMethod=sso\n"

    result_empty_email =
      AgyUsageProbe.parse("/bin/agy", usage_stdout: usage_json, log_content: log_empty_email)

    assert result_empty_email.account_label == "Account unknown"
    assert result_empty_email.account_detail == "sso"

    # Log content nil and non-list groups
    invalid_groups_json = Jason.encode!(%{"status" => "SUCCESS", "command" => %{"data" => %{"groups" => "invalid"}}})
    result_invalid = AgyUsageProbe.parse("/bin/agy", usage_stdout: invalid_groups_json, log_content: nil)
    assert result_invalid.account_label == "Account unknown"
    assert result_invalid.groups == []

    # Probe with executable_path option
    assert %{status: "not_configured"} =
             AgyUsageProbe.probe(
               executable_path: "/custom/bin/agy",
               path_validator: fn _path -> false end
             )

    # Probe with default executable discovery
    assert %{status: "not_configured"} =
             AgyUsageProbe.probe(path_validator: fn _path -> false end)
  end
end
