defmodule Rail.Todos.Actions.UpdateTodo do
  @moduledoc false

  import Rail.Todos.Utils.BroadcastTodosChanged
  import Rail.Todos.Utils.LockTodos

  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Todos.Schemas.Todo
  alias Rail.Users.Schemas.User

  @doc """
  Replaces the text of one of the scope's user's to-dos, leaving its link, place and checked-off time as they are.
  """
  def update_todo(%Scope{user: %User{id: user_id}}, %Todo{id: todo_id}, attrs) do
    result =
      Repo.transaction(fn ->
        :ok = lock_todos(user_id)

        with %Todo{} = todo <- Repo.get_by(Todo, id: todo_id, user_id: user_id),
             {:ok, todo} <- todo |> Todo.changeset(attrs) |> Repo.update() do
          todo
        else
          {:error, %Ecto.Changeset{} = changeset} -> Repo.rollback(changeset)
          nil -> Repo.rollback(:not_found)
        end
      end)

    with {:ok, _todo} <- result, do: broadcast_todos_changed(user_id)
    result
  end

  def update_todo(_scope, _todo, _attrs), do: {:error, :not_authenticated}
end
