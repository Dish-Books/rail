defmodule Rail.Todos.Actions.CompleteTodo do
  @moduledoc false

  import Ecto.Query
  import Rail.Todos.Utils.BroadcastTodosChanged
  import Rail.Todos.Utils.LockTodos
  import Rail.Todos.Utils.PlaceTodo

  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Todos.Schemas.Todo
  alias Rail.Users.Schemas.User

  @doc """
  Checks off one of the scope's user's open to-dos and moves it just below the last open one.
  """
  def complete_todo(%Scope{user: %User{id: user_id}}, %Todo{id: todo_id}) do
    result =
      Repo.transaction(fn ->
        :ok = lock_todos(user_id)
        now = DateTime.utc_now()
        query = from t in Todo, where: t.id == ^todo_id and t.user_id == ^user_id and is_nil(t.completed_at)

        case Repo.update_all(query, set: [completed_at: now, updated_at: now]) do
          {1, _rows} ->
            :ok = place_todo(user_id, todo_id, :after_open)
            Repo.get!(Todo, todo_id)

          {0, _rows} ->
            Repo.rollback(:not_found)
        end
      end)

    with {:ok, _todo} <- result, do: broadcast_todos_changed(user_id)
    result
  end

  def complete_todo(_scope, _todo), do: {:error, :not_authenticated}
end
