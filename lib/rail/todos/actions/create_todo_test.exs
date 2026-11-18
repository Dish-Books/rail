defmodule Rail.Todos.Actions.CreateTodoTest do
  use Rail.DataCase, async: true

  alias Rail.Scope
  alias Rail.Todos
  alias Rail.Todos.Schemas.Todo
  alias Rail.Users

  setup do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Users.register_oauth_user(%{github_id: "gh_create_#{n}", login: "create_#{n}", email: "create_#{n}@example.com"})

    Phoenix.PubSub.subscribe(Rail.PubSub, "todos:#{user.id}")
    %{user: user, scope: Scope.for_user(user)}
  end

  test "adds a typed to-do just below the last open one", %{user: %{id: user_id}, scope: scope} do
    {:ok, _first} = Todos.create_todo(scope, %{"body" => "First"}, :after_open)
    {:ok, done} = Todos.create_todo(scope, %{"body" => "Done"}, :after_open)
    {:ok, _done} = Todos.complete_todo(scope, done)

    assert {:ok, %Todo{body: "Typed", url: nil, user_id: ^user_id, completed_at: nil}} =
             Todos.create_todo(scope, %{"body" => "  Typed "}, :after_open)

    assert ["First", "Typed", "Done"] =
             Repo.all(from t in Todo, where: t.user_id == ^user_id, order_by: t.position, select: t.body)

    assert_received {:todos_changed, ^user_id}
  end

  test "adds a typed to-do below an unchecked one that sits among the checked-off ones",
       %{user: %{id: user_id}, scope: scope} do
    todos =
      for body <- ["Open", "Done 1", "Unchecked", "Done 2"] do
        {:ok, todo} = Todos.create_todo(scope, %{"body" => body}, :last)
        todo
      end

    for todo <- tl(todos), do: {:ok, _checked} = Todos.complete_todo(scope, todo)
    {:ok, _reopened} = Todos.reopen_todo(scope, Enum.at(todos, 2))

    assert {:ok, _typed} = Todos.create_todo(scope, %{"body" => "Typed"}, :after_open)

    # Each check-off lands just below the open ones, so the last one checked off sits highest.
    assert ["Open", "Done 2", "Unchecked", "Typed", "Done 1"] =
             Repo.all(from t in Todo, where: t.user_id == ^user_id, order_by: t.position, select: t.body)
  end

  test "adds a dropped one in front of the row named", %{user: %{id: user_id}, scope: scope} do
    {:ok, _first} = Todos.create_todo(scope, %{"body" => "First"}, :last)
    {:ok, %Todo{id: second_id}} = Todos.create_todo(scope, %{"body" => "Second"}, :last)

    assert {:ok, %Todo{body: "Dropped", position: 1}} = Todos.create_todo(scope, %{"body" => "Dropped"}, second_id)

    assert ["First", "Dropped", "Second"] =
             Repo.all(from t in Todo, where: t.user_id == ^user_id, order_by: t.position, select: t.body)
  end

  test "refuses a blank to-do with nothing renumbered or said", %{user: %{id: user_id}, scope: scope} do
    {:ok, _first} = Todos.create_todo(scope, %{"body" => "First"}, :last)
    assert_received {:todos_changed, ^user_id}
    before = Repo.all(from t in Todo, where: t.user_id == ^user_id, select: {t.id, t.position, t.updated_at})

    assert {:error, %Ecto.Changeset{} = changeset} = Todos.create_todo(scope, %{"body" => "   "}, :after_open)
    assert %{body: ["can't be blank"]} = errors_on(changeset)
    assert ^before = Repo.all(from t in Todo, where: t.user_id == ^user_id, select: {t.id, t.position, t.updated_at})
    refute_received {:todos_changed, _user_id}
  end

  test "refuses a scope with no user" do
    assert {:error, :not_authenticated} = Todos.create_todo(system_scope(), %{"body" => "Nobody's"}, :last)
  end

  test "two adds at once both land, at distinct places", %{user: %{id: user_id}, scope: scope} do
    adds =
      for body <- ["One", "Two"],
          do: Elixir.Task.async(fn -> Todos.create_todo(scope, %{"body" => body}, :after_open) end)

    assert [{:ok, %Todo{}}, {:ok, %Todo{}}] = Elixir.Task.await_many(adds)
    assert [0, 1] = Repo.all(from t in Todo, where: t.user_id == ^user_id, order_by: t.position, select: t.position)
  end
end
