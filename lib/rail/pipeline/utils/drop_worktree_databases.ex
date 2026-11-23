defmodule Rail.Pipeline.Utils.DropWorktreeDatabases do
  @moduledoc """
  Drops the databases a task's worktree made on the Postgres Rail itself uses, once the worktree goes.

  Rail never names them: a project's setup script does, from `RAIL_WORKTREE_SLOT`, and every one so far ends its
  names in `_rail<slot>` (`rail_dev_rail7`, `dishbooks_test_rail7`). The slot is freed with the worktree and the next
  task to claim it sets up afresh, so nothing else is left to use them.
  """

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @connection_opts [:hostname, :port, :socket_dir, :socket_options, :username, :password, :database, :ssl, :parameters]

  @doc """
  Drops every database whose name ends in `_rail<slot>` for `task`'s slot, closing whatever is still connected to
  them. A task with no slot has none. Returns the names dropped.
  """
  def drop_worktree_databases(%Task{worktree_slot: nil}), do: []

  def drop_worktree_databases(%Task{worktree_slot: slot}) when is_integer(slot) do
    # DROP DATABASE refuses to run inside a transaction, which a Repo connection may be in, so this opens its own.
    {:ok, conn} = Repo.config() |> Keyword.take(@connection_opts) |> Postgrex.start_link()

    try do
      %Postgrex.Result{rows: rows} =
        Postgrex.query!(conn, "SELECT datname FROM pg_database WHERE datname ~ $1 ORDER BY datname", ["_rail#{slot}$"])

      for [name] <- rows do
        Postgrex.query!(conn, ~s|DROP DATABASE IF EXISTS "#{String.replace(name, ~s("), ~s(""))}" WITH (FORCE)|, [])
        name
      end
    after
      GenServer.stop(conn)
    end
  end
end
