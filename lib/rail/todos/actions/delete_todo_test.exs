defmodule Rail.Todos.Actions.DeleteTodoTest do
  use Rail.DataCase, async: true

  alias Rail.Scope
  alias Rail.Todos
  alias Rail.Todos.Schemas.Todo
  alias Rail.Users

  setup do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Users.register_oauth_user(%{github_id: "gh_delete_#{n}", login: "delete_#{n}", email: "delete_#{n}@example.com"})

    scope = Scope.for_user(user)

    {:ok, %Todo{id: first_id} = first} = Todos.create_todo(scope, %{"body" => "First"}, :last)
    {:ok, %Todo{id: second_id, position: second_position}} = Todos.create_todo(scope, %{"body" => "Second"}, :last)
    {:ok, done} = Todos.create_todo(scope, %{"body" => "Done"}, :last)
    {:ok, %Todo{id: done_id} = done} = Todos.complete_todo(scope, done)
    Phoenix.PubSub.subscribe(Rail.PubSub, "todos:#{user.id}")

    %{
      user: user,
      scope: scope,
      first: first,
      first_id: first_id,
      second_id: second_id,
      second_position: second_position,
      done: done,
      done_id: done_id
    }
  end

  test "deletes an open to-do and renumbers nothing, once",
       %{
         user: %{id: user_id},
         scope: scope,
         first: first,
         first_id: first_id,
         second_id: second_id,
         second_position: second_position
       } do
    assert {:ok, %Todo{id: ^first_id, body: "First"}} = Todos.delete_todo(scope, first)
    assert_received {:todos_changed, ^user_id}
    assert [%Todo{id: ^second_id, position: ^second_position}] = Todos.list_todos(scope)

    assert {:error, :not_found} = Todos.delete_todo(scope, first)
    refute_received {:todos_changed, _user_id}
  end

  test "deletes a to-do checked off today, which takes it out of the day's CSV", %{
    scope: scope,
    done: done,
    done_id: done_id
  } do
    assert [%Todo{id: ^done_id}] = Todos.list_todos(scope, checked_off_today: "Etc/UTC")

    assert {:ok, %Todo{id: ^done_id}} = Todos.delete_todo(scope, done)

    assert [] = Todos.list_todos(scope, checked_off_today: "Etc/UTC")
    assert {_filename, csv} = Todos.build_todos_csv(scope, "Etc/UTC", "https://rail.example.com/")
    refute csv =~ "Done"
  end

  test "refuses someone else's to-do and a scope with no user", %{scope: scope, first: first} do
    n = System.unique_integer([:positive])

    {:ok, other} =
      Users.register_oauth_user(%{github_id: "gh_delete_o#{n}", login: "delete_o#{n}", email: "delete_o#{n}@example.com"})

    assert {:error, :not_found} = Todos.delete_todo(Scope.for_user(other), first)
    assert {:error, :not_authenticated} = Todos.delete_todo(system_scope(), first)
    refute_received {:todos_changed, _user_id}
    assert [_first, _second] = Todos.list_todos(scope)
  end
end
