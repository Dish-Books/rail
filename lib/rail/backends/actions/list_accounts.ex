defmodule Rail.Backends.Actions.ListAccounts do
  @moduledoc false

  import Ecto.Query

  alias Rail.Backends.Schemas.CliAccount
  alias Rail.Repo

  def list_accounts(opts, []) when is_list(opts) do
    list_accounts(nil, opts)
  end

  def list_accounts(_scope, opts) do
    node = Keyword.get(opts, :node) || CliAccount.default_node()

    Repo.all(
      from(a in CliAccount,
        where: a.node == ^node,
        order_by: [asc: fragment("CASE WHEN backend = 'claude' THEN 1 WHEN backend = 'agy' THEN 2 ELSE 3 END")]
      )
    )
  end
end
