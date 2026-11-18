defmodule Rail.Todos.Utils.PlaceTodoTest do
  use Rail.DataCase, async: true

  import Rail.Todos.Utils.PlaceTodo

  alias Rail.Scope
  alias Rail.Todos
  alias Rail.Todos.Schemas.Todo
  alias Rail.Users

  setup do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Users.register_oauth_user(%{github_id: "gh_place_#{n}", login: "place_#{n}", email: "place_#{n}@example.com"})

    scope = Scope.for_user(user)

    [a, b, c, d] =
      for body <- ["a", "b", "c", "d"] do
        {:ok, todo} = Todos.create_todo(scope, %{"body" => body}, :last)
        todo
      end

    # Checked off just now, so it sits below the open ones.
    Repo.update_all(from(t in Todo, where: t.id == ^d.id), set: [completed_at: DateTime.utc_now()])

    %{user: user, a: a, b: b, c: c, d: d}
  end

  test "places a to-do in front of a row, at the end and just below the last open one",
       %{user: user, a: a, c: c} do
    assert :ok = place_todo(user.id, c.id, a.id)

    assert [{"c", 0}, {"a", 1}, {"b", 2}, {"d", 3}] =
             Repo.all(from t in Todo, where: t.user_id == ^user.id, order_by: t.position, select: {t.body, t.position})

    assert :ok = place_todo(user.id, a.id, :last)

    assert [{"c", 0}, {"b", 1}, {"d", 2}, {"a", 3}] =
             Repo.all(from t in Todo, where: t.user_id == ^user.id, order_by: t.position, select: {t.body, t.position})

    assert :ok = place_todo(user.id, a.id, :after_open)

    assert [{"c", 0}, {"b", 1}, {"a", 2}, {"d", 3}] =
             Repo.all(from t in Todo, where: t.user_id == ^user.id, order_by: t.position, select: {t.body, t.position})
  end

  test "just below the last open to-do is first when none is open", %{user: user, a: a, b: b, c: c} do
    Repo.update_all(from(t in Todo, where: t.id in ^[a.id, b.id]), set: [completed_at: DateTime.utc_now()])

    assert :ok = place_todo(user.id, c.id, :after_open)

    assert ["c", "a", "b", "d"] =
             Repo.all(from t in Todo, where: t.user_id == ^user.id, order_by: t.position, select: t.body)
  end

  test "lands a to-do last when the row named is gone or is the to-do itself", %{user: user, a: a} do
    assert :ok = place_todo(user.id, a.id, "tdo_gone")

    assert ["b", "c", "d", "a"] =
             Repo.all(from t in Todo, where: t.user_id == ^user.id, order_by: t.position, select: t.body)

    assert :ok = place_todo(user.id, a.id, a.id)

    assert ["b", "c", "d", "a"] =
             Repo.all(from t in Todo, where: t.user_id == ^user.id, order_by: t.position, select: t.body)
  end

  test "a to-do checked off 30 hours ago has left the list and nothing is renumbered, one at 25 hours has not",
       %{user: user, a: a, b: b} do
    Repo.update_all(from(t in Todo, where: t.id == ^a.id),
      set: [completed_at: DateTime.shift(DateTime.utc_now(), hour: -30)]
    )

    before =
      Repo.all(from t in Todo, where: t.user_id == ^user.id, order_by: t.id, select: {t.id, t.position, t.updated_at})

    assert :not_found = place_todo(user.id, a.id, :last)

    assert ^before =
             Repo.all(
               from t in Todo, where: t.user_id == ^user.id, order_by: t.id, select: {t.id, t.position, t.updated_at}
             )

    Repo.update_all(from(t in Todo, where: t.id == ^b.id),
      set: [completed_at: DateTime.shift(DateTime.utc_now(), hour: -25)]
    )

    assert :ok = place_todo(user.id, b.id, :last)

    assert [{"c", 0}, {"d", 1}, {"b", 2}] =
             Repo.all(
               from t in Todo,
                 where: t.user_id == ^user.id and t.id != ^a.id,
                 order_by: t.position,
                 select: {t.body, t.position}
             )
  end

  # Hidden from a list in a later zone, yet renumbered, so only the id of the row in front places a drop.
  test "places a to-do in front of the named row with yesterday's checked-off one hidden between",
       %{user: user, b: b, c: c, d: d} do
    Repo.update_all(from(t in Todo, where: t.id == ^b.id),
      set: [completed_at: DateTime.shift(DateTime.utc_now(), hour: -20)]
    )

    assert :ok = place_todo(user.id, d.id, c.id)

    assert ["a", "b", "d", "c"] =
             Repo.all(from t in Todo, where: t.user_id == ^user.id, order_by: t.position, select: t.body)
  end

  test "never touches another person's to-dos", %{a: a} do
    n = System.unique_integer([:positive])

    {:ok, other} =
      Users.register_oauth_user(%{github_id: "gh_place_o#{n}", login: "place_o#{n}", email: "place_o#{n}@example.com"})

    assert :not_found = place_todo(other.id, a.id, :last)
  end
end
