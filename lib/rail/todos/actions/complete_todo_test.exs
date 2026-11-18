defmodule Rail.Todos.Actions.CompleteTodoTest do
  use Rail.DataCase, async: true

  alias Rail.Scope
  alias Rail.Todos
  alias Rail.Todos.Schemas.Todo
  alias Rail.Users
  alias Rail.Users.Schemas.User

  setup do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_complete_#{n}",
        login: "complete_#{n}",
        email: "complete_#{n}@example.com"
      })

    scope = Scope.for_user(user)

    [%Todo{id: first_id} = first, _second, _third, done] =
      for body <- ["First", "Second", "Third", "Done"] do
        {:ok, todo} = Todos.create_todo(scope, %{"body" => body}, :last)
        todo
      end

    {:ok, _done} = Todos.complete_todo(scope, done)
    Phoenix.PubSub.subscribe(Rail.PubSub, "todos:#{user.id}")
    %{user: user, scope: scope, first: first, first_id: first_id}
  end

  test "checks off a to-do and moves it just below the last open one, once",
       %{user: %{id: user_id}, scope: scope, first: first, first_id: first_id} do
    assert {:ok, %Todo{id: ^first_id, completed_at: %DateTime{}, position: 2}} = Todos.complete_todo(scope, first)
    assert_received {:todos_changed, ^user_id}

    assert ["Second", "Third", "First", "Done"] =
             Repo.all(from t in Todo, where: t.user_id == ^user_id, order_by: t.position, select: t.body)

    assert {:error, :not_found} = Todos.complete_todo(scope, first)
    refute_received {:todos_changed, _user_id}
  end

  test "refuses someone else's to-do and a scope with no user", %{first: first} do
    n = System.unique_integer([:positive])

    {:ok, other} =
      Users.register_oauth_user(%{
        github_id: "gh_complete_o#{n}",
        login: "complete_o#{n}",
        email: "complete_o#{n}@example.com"
      })

    assert {:error, :not_found} = Todos.complete_todo(Scope.for_user(other), first)
    assert {:error, :not_authenticated} = Todos.complete_todo(system_scope(), first)
    assert %Todo{completed_at: nil} = Repo.reload!(first)
  end

  # The other tab holds the person's lock while it moves a row, so this check-off waits and works from its result.
  test "a check-off while another tab moves a row takes its turn", %{user: %{id: user_id}, scope: scope, first: first} do
    [_first, _second, third] = Todos.list_todos(scope)

    {:ok, check} =
      Repo.transaction(fn ->
        Repo.one!(from u in User, where: u.id == ^user_id, select: u.id, lock: "FOR NO KEY UPDATE")
        check = Elixir.Task.async(fn -> Todos.complete_todo(scope, first) end)
        {:ok, _moved} = Todos.move_todo(scope, third, first.id)
        check
      end)

    assert {:ok, %Todo{}} = Elixir.Task.await(check)

    assert [{"Third", 0}, {"Second", 1}, {"First", 2}, {"Done", 3}] =
             Repo.all(from t in Todo, where: t.user_id == ^user_id, order_by: t.position, select: {t.body, t.position})
  end
end
