defmodule Rail.Backends.Actions.GetAccountTest do
  use Rail.DataCase, async: true

  alias Rail.Backends
  alias Rail.Backends.Schemas.CliAccount
  alias Rail.Repo
  alias Rail.Scope

  test "get_account/3 retrieves single account by backend atom or string" do
    test_node = "node-get-#{System.unique_integer([:positive])}"

    %CliAccount{id: account_id} =
      Repo.insert!(
        CliAccount.changeset(%CliAccount{}, %{
          node: test_node,
          backend: :claude,
          status: "ready"
        })
      )

    %CliAccount{id: agy_id} =
      Repo.insert!(
        CliAccount.changeset(%CliAccount{}, %{
          node: test_node,
          backend: :agy,
          status: "ready"
        })
      )

    assert %CliAccount{id: ^account_id} = Backends.get_account(:claude, node: test_node)
    assert %CliAccount{id: ^account_id} = Backends.get_account("claude", node: test_node)
    assert %CliAccount{id: ^agy_id} = Backends.get_account(:agy, node: test_node)
    assert %CliAccount{id: ^agy_id} = Backends.get_account("agy", node: test_node)

    scope = Scope.for_system()
    assert %CliAccount{id: ^account_id} = Backends.get_account(scope, :claude, node: test_node)

    # 1-arity and 2-arity calls against default node
    %CliAccount{id: default_id} =
      Repo.insert!(
        CliAccount.changeset(%CliAccount{}, %{
          node: CliAccount.default_node(),
          backend: :claude,
          status: "ready"
        })
      )

    assert %CliAccount{id: ^default_id} = Backends.get_account(:claude)
    assert %CliAccount{id: ^default_id} = Backends.get_account(scope, :claude)

    assert is_nil(Backends.get_account("invalid_backend", node: test_node))
  end
end
