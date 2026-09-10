defmodule Rail.Backends.Actions.RefreshUsageTest do
  use Rail.DataCase, async: false

  alias Rail.Backends
  alias Rail.Backends.Schemas.CliAccount
  alias Rail.Scope

  test "refresh_usage/2 probes backends, upserts into cli_accounts, and broadcasts on PubSub" do
    test_node = "node-refresh-#{System.unique_integer([:positive])}"

    # Subscribe to PubSub
    Phoenix.PubSub.subscribe(Rail.PubSub, "backends:usage_updated")

    runner = fn exe, _args, _opts ->
      case exe do
        "claude" ->
          {:ok, ~s({"loggedIn":true,"email":"claude@example.com","subscriptionType":"Pro"}), 0}

        _agy ->
          {:ok,
           ~s({"status":"SUCCESS","command":{"data":{"groups":[{"name":"Gemini Models","buckets":[{"window":"5h","remaining_fraction":0.85,"reset_time":"2026-09-09T20:00:00Z"},{"window":"weekly","remaining_fraction":0.6,"reset_time":"2026-09-16T20:00:00Z"}]}]}}}),
           0}
      end
    end

    refresh_opts = [
      node: test_node,
      direct: true,
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
          {:ok, ~s(2026-09-09T15:00:00.123Z INFO [Auth] applyAuthResult: email=agy@example.com, authMethod=oauth\n)}
        end
      ]
    ]

    assert {:ok,
            [
              %CliAccount{id: claude_id, backend: :claude, account_label: "claude@example.com", status: "ready"},
              %CliAccount{id: agy_id, backend: :agy, account_label: "agy@example.com", status: "ready"}
            ]} = Backends.refresh_usage(refresh_opts)

    # PubSub broadcast received
    assert_receive {:usage_updated, [%CliAccount{id: ^claude_id}, %CliAccount{id: ^agy_id}]}

    # Refreshing a second time updates existing records rather than creating new ones
    assert {:ok, [%CliAccount{id: ^claude_id}, %CliAccount{id: ^agy_id}]} =
             Backends.refresh_usage(Scope.for_system(), refresh_opts)

    # Refresh without direct: true delegates through RefreshServer
    assert {:ok, [%CliAccount{id: ^claude_id}, %CliAccount{id: ^agy_id}]} =
             Backends.refresh_usage(Keyword.delete(refresh_opts, :direct))
  end
end
