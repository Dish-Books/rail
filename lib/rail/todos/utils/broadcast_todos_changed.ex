defmodule Rail.Todos.Utils.BroadcastTodosChanged do
  @moduledoc """
  Says on `"todos:<user id>"` that a person's to-dos changed, once the write is committed.
  """

  @doc """
  Broadcasts `{:todos_changed, user_id}` to that person's pages alone.
  """
  def broadcast_todos_changed(user_id) when is_binary(user_id) do
    Phoenix.PubSub.broadcast(Rail.PubSub, "todos:#{user_id}", {:todos_changed, user_id})
  end
end
