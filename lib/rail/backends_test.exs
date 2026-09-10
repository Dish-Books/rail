defmodule Rail.BackendsTest do
  use Rail.DataCase, async: false

  import RailTest.BackendsHelpers

  alias Rail.Backends
  alias Rail.Backends.ModelOption
  alias Rail.Backends.Schemas.CliAccount
  alias Rail.Scope

  test "list_accounts/2 returns accounts for node ordered with claude first then agy" do
    test_node = "node-list-#{System.unique_integer([:positive])}"

    %CliAccount{id: account_agy_id} =
      create_test_cli_account(%{
        node: test_node,
        backend: :agy,
        status: "ready"
      })

    %CliAccount{id: account_claude_id} =
      create_test_cli_account(%{
        node: test_node,
        backend: :claude,
        status: "ready"
      })

    assert [
             %CliAccount{id: ^account_claude_id, backend: :claude},
             %CliAccount{id: ^account_agy_id, backend: :agy}
           ] = Backends.list_accounts(node: test_node)

    # Works with no args on default node
    %CliAccount{} =
      create_test_cli_account(%{
        backend: :claude,
        status: "ready"
      })

    assert [%CliAccount{} | _all_accounts] = Backends.list_accounts()

    # Works with explicit scope
    scope = Scope.for_system()

    assert [
             %CliAccount{id: ^account_claude_id, backend: :claude},
             %CliAccount{id: ^account_agy_id, backend: :agy}
           ] = Backends.list_accounts(scope, node: test_node)
  end

  test "get_account/3 retrieves single account by backend atom or string" do
    test_node = "node-get-#{System.unique_integer([:positive])}"

    %CliAccount{id: account_id} =
      create_test_cli_account(%{
        node: test_node,
        backend: :claude,
        status: "ready"
      })

    %CliAccount{id: agy_id} =
      create_test_cli_account(%{
        node: test_node,
        backend: :agy,
        status: "ready"
      })

    assert %CliAccount{id: ^account_id} = Backends.get_account(:claude, node: test_node)
    assert %CliAccount{id: ^account_id} = Backends.get_account("claude", node: test_node)
    assert %CliAccount{id: ^agy_id} = Backends.get_account(:agy, node: test_node)
    assert %CliAccount{id: ^agy_id} = Backends.get_account("agy", node: test_node)

    scope = Scope.for_system()
    assert %CliAccount{id: ^account_id} = Backends.get_account(scope, :claude, node: test_node)

    # 1-arity and 2-arity calls against default node
    %CliAccount{id: default_id} =
      create_test_cli_account(%{
        backend: :claude,
        status: "ready"
      })

    assert %CliAccount{id: ^default_id} = Backends.get_account(:claude)
    assert %CliAccount{id: ^default_id} = Backends.get_account(scope, :claude)

    assert is_nil(Backends.get_account("invalid_backend", node: test_node))
  end

  test "refresh_usage/2 probes backends, upserts into cli_accounts, and broadcasts on PubSub" do
    test_node = "node-refresh-#{System.unique_integer([:positive])}"

    # Subscribe to PubSub
    Phoenix.PubSub.subscribe(Rail.PubSub, "backends:usage_updated")

    runner = fn exe, _args, _opts ->
      case exe do
        "claude" ->
          {:ok, sample_claude_auth_json(%{"email" => "claude@example.com"}), 0}

        _agy ->
          {:ok, sample_agy_usage_json(), 0}
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
        config_file_reader: fn _path -> {:ok, sample_claude_config_json()} end
      ],
      agy_opts: [
        executable: "agy",
        path_validator: fn _path -> true end,
        runner: runner,
        file_reader: fn _path -> {:ok, sample_agy_scratch_log("agy@example.com")} end
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

  test "fetch_available_models/3 delegates to ModelRegistry" do
    mock_runner = fn _exe, _args, _opts -> {:ok, "", 0} end

    models = Backends.fetch_available_models(:claude, runner: mock_runner, force_refresh: true)
    assert [%ModelOption{} | _models1] = models

    scope = Scope.for_system()

    models_with_scope =
      Backends.fetch_available_models(scope, :agy, runner: mock_runner, force_refresh: true)

    assert [%ModelOption{} | _models2] = models_with_scope

    models_with_opts = Backends.fetch_available_models(scope, :agy, force_refresh: false)
    assert [%ModelOption{} | _models3] = models_with_opts

    # 1-arity and 2-arity calls
    assert [%ModelOption{} | _models4] = Backends.fetch_available_models(:claude)
    assert [%ModelOption{} | _models5] = Backends.fetch_available_models(scope, :claude)
  end
end
