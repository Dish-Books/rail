defmodule Rail.Backends.Schemas.CliAccountTest do
  use Rail.DataCase, async: true

  import RailTest.BackendsHelpers

  alias Rail.Backends.Schemas.CliAccount
  alias Rail.Domain.Embeds.CliAccountGroup
  alias Rail.Repo

  test "factory/0 builds a valid struct" do
    account = CliAccount.factory()
    assert account.backend == :claude
    assert account.status == "ready"
    assert account.account_label == "test@example.com"
    assert account.account_detail == "max"
    assert [%CliAccountGroup{}] = account.groups
    assert %DateTime{} = account.fetched_at
    assert byte_size(account.node) > 0
  end

  test "changeset/2 validates required fields and status inclusion" do
    changeset = CliAccount.changeset(%CliAccount{}, %{backend: nil, status: nil})
    refute changeset.valid?
    assert %{backend: ["can't be blank"], status: ["can't be blank"]} = errors_on(changeset)

    invalid_status = CliAccount.changeset(%CliAccount{}, %{backend: :claude, status: "unknown"})
    refute invalid_status.valid?
    assert %{status: ["is invalid"]} = errors_on(invalid_status)

    invalid_backend = CliAccount.changeset(%CliAccount{}, %{backend: "unknown_backend", status: "ready"})
    refute invalid_backend.valid?
    assert %{backend: ["is invalid"]} = errors_on(invalid_backend)

    for status <- ["not_configured", "signed_out", "unavailable", "ready"] do
      valid = CliAccount.changeset(%CliAccount{}, %{backend: :claude, status: status})
      assert valid.valid?
      assert Ecto.Changeset.get_field(valid, :status) == status
    end
  end

  test "backends/0 returns all supported backend atoms" do
    assert CliAccount.backends() == [:claude, :agy, :codex]
  end

  test "changeset/2 defaults node when nil or empty" do
    changeset_nil = CliAccount.changeset(%CliAccount{}, %{backend: :claude, status: "ready", node: nil})
    assert changeset_nil.valid?
    assert Ecto.Changeset.get_field(changeset_nil, :node) == CliAccount.default_node()

    changeset_empty = CliAccount.changeset(%CliAccount{}, %{backend: :claude, status: "ready", node: ""})
    assert changeset_empty.valid?
    assert Ecto.Changeset.get_field(changeset_empty, :node) == CliAccount.default_node()

    changeset_custom =
      CliAccount.changeset(%CliAccount{}, %{backend: :claude, status: "ready", node: "worker-node-1"})

    assert changeset_custom.valid?
    assert Ecto.Changeset.get_field(changeset_custom, :node) == "worker-node-1"
    assert CliAccount.default_node(:cluster_node_1) == "cluster_node_1"
  end

  test "changeset/2 casts embedded groups and persists to database" do
    account =
      create_test_cli_account(%{
        backend: :agy,
        status: "ready",
        groups: [
          %{
            name: "Antigravity Limits",
            count: 2,
            details: %{"windows" => [%{"label" => "5-Hour", "remaining_percent" => 95.0}]}
          }
        ]
      })

    assert account.id =~ ~r/^cli_/
    assert account.backend == :agy
    assert [%CliAccountGroup{name: "Antigravity Limits", count: 2, details: details}] = account.groups
    assert %{"windows" => [%{"label" => "5-Hour", "remaining_percent" => 95.0}]} = details
  end

  test "unique constraint enforced on [:node, :backend]" do
    node_name = "test-node-#{System.unique_integer([:positive])}"
    create_test_cli_account(%{node: node_name, backend: :claude})

    duplicate_changeset =
      CliAccount.changeset(%CliAccount{}, valid_cli_account_attrs(%{node: node_name, backend: :claude}))

    assert {:error, changeset} = Repo.insert(duplicate_changeset)
    assert %{node: ["has already been taken"]} = errors_on(changeset)
  end
end
