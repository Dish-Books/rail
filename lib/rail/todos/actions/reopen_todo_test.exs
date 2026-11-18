defmodule Rail.Todos.Actions.ReopenTodoTest do
  use Rail.DataCase, async: true

  alias Rail.Scope
  alias Rail.Todos
  alias Rail.Todos.Schemas.Todo
  alias Rail.Users

  setup do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Users.register_oauth_user(%{github_id: "gh_reopen_#{n}", login: "reopen_#{n}", email: "reopen_#{n}@example.com"})

    scope = Scope.for_user(user)
    {:ok, _open} = Todos.create_todo(scope, %{"body" => "Open"}, :last)
    {:ok, done} = Todos.create_todo(scope, %{"body" => "Done"}, :last)
    {:ok, _later} = Todos.create_todo(scope, %{"body" => "Later"}, :last)
    {:ok, %Todo{id: done_id, position: position} = done} = Todos.complete_todo(scope, done)
    Phoenix.PubSub.subscribe(Rail.PubSub, "todos:#{user.id}")
    %{user: user, scope: scope, done: done, done_id: done_id, position: position}
  end

  test "unchecks a to-do where it stands, once",
       %{user: %{id: user_id}, scope: scope, done: done, done_id: done_id, position: position} do
    assert {:ok, %Todo{id: ^done_id, completed_at: nil, position: ^position}} = Todos.reopen_todo(scope, done)
    assert_received {:todos_changed, ^user_id}

    assert ["Open", "Later", "Done"] =
             Repo.all(from t in Todo, where: t.user_id == ^user_id, order_by: t.position, select: t.body)

    assert {:error, :not_found} = Todos.reopen_todo(scope, done)
    refute_received {:todos_changed, _user_id}
  end

  test "refuses someone else's to-do and a scope with no user", %{done: done} do
    n = System.unique_integer([:positive])

    {:ok, other} =
      Users.register_oauth_user(%{github_id: "gh_reopen_o#{n}", login: "reopen_o#{n}", email: "reopen_o#{n}@example.com"})

    assert {:error, :not_found} = Todos.reopen_todo(Scope.for_user(other), done)
    assert {:error, :not_authenticated} = Todos.reopen_todo(system_scope(), done)
    assert %Todo{completed_at: %DateTime{}} = Repo.reload!(done)
  end
end
