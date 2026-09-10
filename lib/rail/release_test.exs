defmodule Rail.ReleaseTest do
  use Rail.DataCase, async: true

  alias Rail.Release
  alias Rail.Repo

  test "migrate/0 runs pending migrations" do
    assert [[]] = Release.migrate()
  end

  test "rollback/2 rolls back with integer version" do
    assert [] = Release.rollback(Repo, 99_999_999_999_999)
  end

  test "rollback/2 rolls back with string version" do
    assert [] = Release.rollback(Repo, "99999999999999")
  end

  test "rollback/1 rolls back with default repo" do
    assert [] = Release.rollback(99_999_999_999_999)
  end

  test "seed/0 runs seeds and returns success tuple" do
    assert [{:ok, %{admin_user: %{email: "admin@rail.local"}, project: %{name: "Rail"}}}] =
             Release.seed()
  end

  test "seed/1 returns error when seeds file does not exist" do
    assert [{:error, :seeds_not_found}] = Release.seed("/nonexistent/path/seeds.exs")
  end
end
