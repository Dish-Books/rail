defmodule Rail.Backends.Actions.RefreshUsage do
  @moduledoc false

  alias Rail.Backends.Probes.AgyUsageProbe
  alias Rail.Backends.Probes.ClaudeUsageProbe
  alias Rail.Backends.RefreshServer
  alias Rail.Backends.Schemas.CliAccount
  alias Rail.Repo

  def refresh_usage(opts, []) when is_list(opts) do
    refresh_usage(nil, opts)
  end

  def refresh_usage(_scope, opts) do
    if RefreshServer.running?() and not Keyword.get(opts, :direct, false) do
      RefreshServer.refresh(opts)
    else
      do_refresh(opts)
    end
  end

  def do_refresh(opts \\ []) do
    claude_opts = Keyword.get(opts, :claude_opts, [])
    agy_opts = Keyword.get(opts, :agy_opts, [])
    node = Keyword.get(opts, :node) || CliAccount.default_node()

    claude_task = Task.async(fn -> ClaudeUsageProbe.probe(claude_opts) end)
    agy_task = Task.async(fn -> AgyUsageProbe.probe(agy_opts) end)

    claude_raw = Task.await(claude_task, 35_000)
    agy_raw = Task.await(agy_task, 35_000)

    claude_account = upsert_account(Map.put(claude_raw, :node, node))
    agy_account = upsert_account(Map.put(agy_raw, :node, node))

    {:ok, [claude_account, agy_account]}
  end

  defp upsert_account(attrs) do
    changeset = CliAccount.changeset(%CliAccount{}, attrs)

    Repo.insert!(
      changeset,
      on_conflict: {
        :replace,
        [:status, :account_label, :account_detail, :groups, :fetched_at, :unavailable_reason, :updated_at]
      },
      conflict_target: [:node, :backend],
      returning: true
    )
  end
end
