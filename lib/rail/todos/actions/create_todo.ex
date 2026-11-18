defmodule Rail.Todos.Actions.CreateTodo do
  @moduledoc false

  import Rail.Todos.Utils.BroadcastTodosChanged
  import Rail.Todos.Utils.LockTodos
  import Rail.Todos.Utils.PlaceTodo

  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Todos.Schemas.Todo
  alias Rail.Users.Schemas.User

  @doc """
  Adds a typed or dropped-text to-do at `place` in the scope's user's list, under their lock.
  """
  def create_todo(%Scope{user: %User{id: user_id}}, attrs, place) do
    result =
      Repo.transaction(fn ->
        :ok = lock_todos(user_id)

        case %Todo{user_id: user_id} |> Todo.changeset(attrs) |> Repo.insert() do
          {:ok, todo} ->
            :ok = place_todo(user_id, todo.id, place)
            Repo.get!(Todo, todo.id)

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)

    with {:ok, _todo} <- result, do: broadcast_todos_changed(user_id)
    result
  end

  def create_todo(_scope, _attrs, _place), do: {:error, :not_authenticated}
end
