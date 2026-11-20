defmodule Rail.Pipeline.Utils.DropWorktreeDatabasesTest do
  use Rail.DataCase, async: true

  import Rail.Pipeline.Utils.DropWorktreeDatabases

  alias Rail.Pipeline.Schemas.Task

  # The databases are real ones on the test Postgres, so the slot is one no worktree on this machine holds.
  @moduletag :real_worktree_databases

  setup do
    slot = 900_000_000 + System.unique_integer([:positive])

    {:ok, conn} =
      Repo.config() |> Keyword.take([:hostname, :port, :username, :password, :database]) |> Postgrex.start_link()

    names = ["app_dev_rail#{slot}", "app_test_rail#{slot}", "app_dev_rail#{slot}0"]
    for name <- names, do: Postgrex.query!(conn, ~s(CREATE DATABASE "#{name}" TEMPLATE template0), [])

    on_exit(fn ->
      {:ok, cleanup} =
        Repo.config() |> Keyword.take([:hostname, :port, :username, :password, :database]) |> Postgrex.start_link()

      for name <- names, do: Postgrex.query!(cleanup, ~s|DROP DATABASE IF EXISTS "#{name}" WITH (FORCE)|, [])
    end)

    %{slot: slot, conn: conn}
  end

  test "drops the slot's databases, even one still in use, and leaves a longer slot's alone", %{slot: slot, conn: conn} do
    # A dev server left running in the worktree would hold a connection like this one. It dies with its database.
    Process.flag(:trap_exit, true)

    {:ok, in_use} =
      Repo.config()
      |> Keyword.take([:hostname, :port, :username, :password])
      |> Keyword.merge(database: "app_dev_rail#{slot}", backoff_type: :stop)
      |> Postgrex.start_link()

    Postgrex.query!(in_use, "SELECT 1", [])

    assert drop_worktree_databases(%Task{worktree_slot: slot}) == ["app_dev_rail#{slot}", "app_test_rail#{slot}"]

    longer = "app_dev_rail#{slot}0"

    assert %Postgrex.Result{rows: [[^longer]]} =
             Postgrex.query!(conn, "SELECT datname FROM pg_database WHERE datname LIKE $1", ["app_%_rail#{slot}%"])
  end

  test "a task with no slot has no databases to drop" do
    assert drop_worktree_databases(%Task{worktree_slot: nil}) == []
  end
end
