defmodule Rail.Todos.Actions.MoveTodo do
  @moduledoc false

  import Rail.Todos.Utils.BroadcastTodosChanged
  import Rail.Todos.Utils.LockTodos
  import Rail.Todos.Utils.PlaceTodo

  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Todos.Schemas.Todo
  alias Rail.Users.Schemas.User

  @doc """
  Moves one of the scope's user's listed to-dos to `place`. One that has left the list, or is someone
  else's, is not found.
  """
  def move_todo(%Scope{user: %User{id: user_id}}, %Todo{id: todo_id}, place) do
    result =
      Repo.transaction(fn ->
        :ok = lock_todos(user_id)

        case place_todo(user_id, todo_id, place) do
          :ok -> Repo.get!(Todo, todo_id)
          :not_found -> Repo.rollback(:not_found)
        end
      end)

    with {:ok, _todo} <- result, do: broadcast_todos_changed(user_id)
    result
  end

  def move_todo(_scope, _todo, _place), do: {:error, :not_authenticated}
end
