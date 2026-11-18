defmodule Rail.Todos.Actions.MoveTodoTest do
  use Rail.DataCase, async: true

  alias Rail.Scope
  alias Rail.Todos
  alias Rail.Todos.Schemas.Todo
  alias Rail.Users

  setup do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Users.register_oauth_user(%{github_id: "gh_move_#{n}", login: "move_#{n}", email: "move_#{n}@example.com"})

    scope = Scope.for_user(user)
    {:ok, open} = Todos.create_todo(scope, %{"body" => "Open"}, :last)
    {:ok, done} = Todos.create_todo(scope, %{"body" => "Done"}, :last)
    {:ok, %Todo{id: done_id} = done} = Todos.complete_todo(scope, done)
    Phoenix.PubSub.subscribe(Rail.PubSub, "todos:#{user.id}")
    %{user: user, scope: scope, open: open, done: done, done_id: done_id}
  end

  test "moves a checked-off to-do above an open one",
       %{user: %{id: user_id}, scope: scope, open: open, done: done, done_id: done_id} do
    assert {:ok, %Todo{id: ^done_id, position: 0, completed_at: %DateTime{}}} = Todos.move_todo(scope, done, open.id)
    assert ["Done", "Open"] = Repo.all(from t in Todo, where: t.user_id == ^user_id, order_by: t.position, select: t.body)
    assert_received {:todos_changed, ^user_id}
  end

  test "refuses a to-do that has left the list, someone else's, and a scope with no user, renumbering nothing",
       %{user: %{id: user_id}, scope: scope, open: open, done: done} do
    Repo.update_all(from(t in Todo, where: t.id == ^done.id),
      set: [completed_at: DateTime.shift(DateTime.utc_now(), hour: -30)]
    )

    before = Repo.all(from t in Todo, where: t.user_id == ^user_id, select: {t.id, t.position, t.updated_at})

    n = System.unique_integer([:positive])

    {:ok, other} =
      Users.register_oauth_user(%{github_id: "gh_move_o#{n}", login: "move_o#{n}", email: "move_o#{n}@example.com"})

    assert {:error, :not_found} = Todos.move_todo(scope, done, open.id)
    assert {:error, :not_found} = Todos.move_todo(Scope.for_user(other), open, :last)
    assert {:error, :not_authenticated} = Todos.move_todo(system_scope(), open, :last)

    assert ^before = Repo.all(from t in Todo, where: t.user_id == ^user_id, select: {t.id, t.position, t.updated_at})
    refute_received {:todos_changed, _user_id}
  end
end
