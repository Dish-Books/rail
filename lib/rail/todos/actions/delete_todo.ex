defmodule Rail.Todos.Actions.DeleteTodo do
  @moduledoc false

  import Ecto.Query
  import Rail.Todos.Utils.BroadcastTodosChanged
  import Rail.Todos.Utils.LockTodos

  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Todos.Schemas.Todo
  alias Rail.Users.Schemas.User

  @doc """
  Deletes one of the scope's user's to-dos and returns it. It renumbers nothing; the lock keeps it out of an edit.
  """
  def delete_todo(%Scope{user: %User{id: user_id}}, %Todo{id: todo_id}) do
    result =
      Repo.transaction(fn ->
        :ok = lock_todos(user_id)

        case Repo.delete_all(from(t in Todo, where: t.id == ^todo_id and t.user_id == ^user_id, select: t)) do
          {1, [todo]} -> todo
          {0, []} -> Repo.rollback(:not_found)
        end
      end)

    with {:ok, _todo} <- result, do: broadcast_todos_changed(user_id)
    result
  end

  def delete_todo(_scope, _todo), do: {:error, :not_authenticated}
end
