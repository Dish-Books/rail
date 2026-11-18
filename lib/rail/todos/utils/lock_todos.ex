defmodule Rail.Todos.Utils.LockTodos do
  @moduledoc """
  Takes a person's turn at their to-do list for the rest of the transaction.
  """

  import Ecto.Query

  alias Rail.Repo
  alias Rail.Users.Schemas.User

  @doc """
  Locks the user row. Call it first in the transaction, before any insert or update.
  """
  # The user row, not the to-dos: Postgres orders rows before it waits on their locks. NO KEY UPDATE does not
  # wait on the key-share lock a to-do's insert takes through its foreign key.
  def lock_todos(user_id) when is_binary(user_id) do
    Repo.one!(from u in User, where: u.id == ^user_id, select: u.id, lock: "FOR NO KEY UPDATE")
    :ok
  end
end
