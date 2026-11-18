defmodule Rail.Todos.Actions.ListTodosTest do
  use Rail.DataCase, async: true

  alias Rail.Scope
  alias Rail.Todos
  alias Rail.Todos.Schemas.Todo
  alias Rail.Users

  setup do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Users.register_oauth_user(%{github_id: "gh_list_#{n}", login: "list_#{n}", email: "list_#{n}@example.com"})

    {:ok, other} =
      Users.register_oauth_user(%{github_id: "gh_list_o#{n}", login: "list_o#{n}", email: "list_o#{n}@example.com"})

    %{scope: Scope.for_user(user), other_scope: Scope.for_user(other)}
  end

  # New York is five hours behind UTC in November, so its Nov 18 runs from 05:00 to 05:00 the next day, UTC.
  test "lists the to-dos checked off on that day in the zone given, in the order they were checked off",
       %{scope: scope, other_scope: other_scope} do
    {:ok, %Todo{id: late_id}} = Todos.create_todo(scope, %{"body" => "Checked off late"}, :last)
    {:ok, %Todo{id: early_id}} = Todos.create_todo(scope, %{"body" => "Checked off early"}, :last)
    {:ok, %Todo{id: evening_id}} = Todos.create_todo(scope, %{"body" => "The evening before"}, :last)
    {:ok, _open} = Todos.create_todo(scope, %{"body" => "Still open"}, :last)
    {:ok, unchecked} = Todos.create_todo(scope, %{"body" => "Unchecked"}, :last)
    {:ok, %Todo{id: theirs_id}} = Todos.create_todo(other_scope, %{"body" => "Someone else's"}, :last)

    for {id, at} <- [
          {late_id, ~U[2026-11-19 04:59:00Z]},
          {early_id, ~U[2026-11-18 05:00:00Z]},
          {evening_id, ~U[2026-11-18 04:59:59Z]},
          {theirs_id, ~U[2026-11-18 12:00:00Z]}
        ] do
      Repo.update_all(from(t in Todo, where: t.id == ^id), set: [completed_at: at])
    end

    {:ok, _checked} = Todos.complete_todo(scope, unchecked)
    {:ok, _reopened} = Todos.reopen_todo(scope, unchecked)

    assert [%Todo{id: ^early_id}, %Todo{id: ^late_id}] =
             Todos.list_todos(scope, checked_off_today: "America/New_York", now: ~U[2026-11-18 15:00:00Z])
  end

  test "lists only the open to-dos by default, in their order", %{scope: scope} do
    {:ok, %Todo{id: first_id}} = Todos.create_todo(scope, %{"body" => "First"}, :last)
    {:ok, done} = Todos.create_todo(scope, %{"body" => "Done"}, :last)
    {:ok, %Todo{id: second_id}} = Todos.create_todo(scope, %{"body" => "Second"}, first_id)
    {:ok, _done} = Todos.complete_todo(scope, done)

    assert [%Todo{id: ^second_id}, %Todo{id: ^first_id}] = Todos.list_todos(scope)
  end

  test "a scope with no user lists nothing" do
    assert [] = Todos.list_todos(system_scope())
    assert [] = Todos.list_todos(system_scope(), checked_off_today: "Etc/UTC")
  end
end
