defmodule Rail.Backends.Actions.ListAccountsTest do
  use Rail.DataCase, async: false

  alias Rail.Backends
  alias Rail.Backends.Schemas.CliAccount
  alias Rail.Repo
  alias Rail.Scope

  test "list_accounts/2 returns accounts for node ordered with claude first then agy" do
    test_node = "node-list-#{System.unique_integer([:positive])}"

    %CliAccount{id: account_agy_id} =
      Repo.insert!(
        CliAccount.changeset(%CliAccount{}, %{
          node: test_node,
          backend: :agy,
          status: "ready"
        })
      )

    %CliAccount{id: account_claude_id} =
      Repo.insert!(
        CliAccount.changeset(%CliAccount{}, %{
          node: test_node,
          backend: :claude,
          status: "ready"
        })
      )

    assert [
             %CliAccount{id: ^account_claude_id, backend: :claude},
             %CliAccount{id: ^account_agy_id, backend: :agy}
           ] = Backends.list_accounts(node: test_node)

    # Works with no args on default node
    %CliAccount{} =
      Repo.insert!(
        CliAccount.changeset(%CliAccount{}, %{
          node: CliAccount.default_node(),
          backend: :claude,
          status: "ready"
        })
      )

    assert [%CliAccount{} | _all_accounts] = Backends.list_accounts()

    # Works with explicit scope
    scope = Scope.for_system()

    assert [
             %CliAccount{id: ^account_claude_id, backend: :claude},
             %CliAccount{id: ^account_agy_id, backend: :agy}
           ] = Backends.list_accounts(scope, node: test_node)
  end
end
