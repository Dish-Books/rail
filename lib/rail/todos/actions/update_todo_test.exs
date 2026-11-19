defmodule Rail.Todos.Actions.UpdateTodoTest do
  use Rail.DataCase, async: true

  alias Rail.Scope
  alias Rail.Todos
  alias Rail.Todos.Schemas.Todo
  alias Rail.Users
  alias Rail.Users.Schemas.User

  setup do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Users.register_oauth_user(%{github_id: "gh_update_#{n}", login: "update_#{n}", email: "update_#{n}@example.com"})

    scope = Scope.for_user(user)
    {:ok, _first} = Todos.create_todo(scope, %{"body" => "First"}, :last)
    {:ok, link} = Todos.add_link_todo(scope, "/triage/thr_1", "Demo video won't play in Safari", :last)
    {:ok, %Todo{id: link_id, position: position, completed_at: completed_at} = link} = Todos.complete_todo(scope, link)
    Phoenix.PubSub.subscribe(Rail.PubSub, "todos:#{user.id}")

    %{
      user: user,
      scope: scope,
      link: link,
      link_id: link_id,
      position: position,
      completed_at: completed_at
    }
  end

  test "replaces a checked-off link's text and leaves its address, place and checked-off time",
       %{
         user: %{id: user_id},
         scope: scope,
         link: link,
         link_id: link_id,
         position: position,
         completed_at: completed_at
       } do
    assert {:ok,
            %Todo{
              id: ^link_id,
              body: "Safari: demo video won't play",
              url: "/triage/thr_1",
              position: ^position,
              completed_at: ^completed_at
            }} = Todos.update_todo(scope, link, %{"body" => " Safari: demo video won't play ", "url" => "/x"})

    assert %Todo{body: "Safari: demo video won't play", url: "/triage/thr_1", position: ^position} = Repo.reload!(link)
    assert_received {:todos_changed, ^user_id}
    refute_received {:todos_changed, _user_id}
  end

  test "refuses blank text and leaves the to-do as it was", %{scope: scope, link: link} do
    assert {:error, %Ecto.Changeset{} = changeset} = Todos.update_todo(scope, link, %{"body" => "  "})
    assert %{body: ["can't be blank"]} = errors_on(changeset)
    assert %Todo{body: "Demo video won't play in Safari"} = Repo.reload!(link)
    refute_received {:todos_changed, _user_id}
  end

  test "refuses someone else's to-do, a deleted one and a scope with no user", %{scope: scope, link: link} do
    n = System.unique_integer([:positive])

    {:ok, other} =
      Users.register_oauth_user(%{github_id: "gh_update_o#{n}", login: "update_o#{n}", email: "update_o#{n}@example.com"})

    assert {:error, :not_found} = Todos.update_todo(Scope.for_user(other), link, %{"body" => "Theirs"})
    assert {:error, :not_authenticated} = Todos.update_todo(system_scope(), link, %{"body" => "Nobody's"})
    assert %Todo{body: "Demo video won't play in Safari"} = Repo.reload!(link)

    {:ok, _deleted} = Todos.delete_todo(scope, link)
    assert_received {:todos_changed, _user_id}
    assert {:error, :not_found} = Todos.update_todo(scope, link, %{"body" => "Gone"})
    refute_received {:todos_changed, _user_id}
  end

  # The other tab holds the person's lock while it deletes, so this edit waits and finds the row gone.
  test "an edit while another tab deletes the row finds it gone", %{user: %{id: user_id}, scope: scope, link: link} do
    {:ok, edit} =
      Repo.transaction(fn ->
        Repo.one!(from u in User, where: u.id == ^user_id, select: u.id, lock: "FOR NO KEY UPDATE")
        edit = Elixir.Task.async(fn -> Todos.update_todo(scope, link, %{"body" => "Too late"}) end)
        {:ok, _deleted} = Todos.delete_todo(scope, link)
        edit
      end)

    assert {:error, :not_found} = Elixir.Task.await(edit)
    refute Repo.get(Todo, link.id)
  end
end
