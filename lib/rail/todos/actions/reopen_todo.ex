defmodule Rail.Todos.Actions.ReopenTodo do
  @moduledoc false

  import Ecto.Query
  import Rail.Todos.Utils.BroadcastTodosChanged

  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Todos.Schemas.Todo
  alias Rail.Users.Schemas.User

  @doc """
  Unchecks one of the scope's user's checked-off to-dos where it stands. It renumbers nothing, so takes no lock.
  """
  def reopen_todo(%Scope{user: %User{id: user_id}}, %Todo{id: todo_id}) do
    query =
      from t in Todo,
        where: t.id == ^todo_id and t.user_id == ^user_id and not is_nil(t.completed_at),
        select: t

    case Repo.update_all(query, set: [completed_at: nil, updated_at: DateTime.utc_now()]) do
      {1, [todo]} ->
        broadcast_todos_changed(user_id)
        {:ok, todo}

      {0, []} ->
        {:error, :not_found}
    end
  end

  def reopen_todo(_scope, _todo), do: {:error, :not_authenticated}
end
