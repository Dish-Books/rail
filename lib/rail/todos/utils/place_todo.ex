defmodule Rail.Todos.Utils.PlaceTodo do
  @moduledoc """
  Puts a to-do at a place in its person's list and renumbers the list from 0.
  """

  import Ecto.Query

  alias Rail.Repo
  alias Rail.Todos.Schemas.Todo

  # Today's checked-off to-dos in every time zone fall inside this; older ones are no longer listed.
  @recent_hours 26

  @doc """
  Places `todo_id` at `place`: `:after_open`, `:last`, or in front of the to-do whose id it is. A row that is
  gone, or the to-do itself, lands it last. Returns `:not_found` when the to-do has left the list.
  """
  def place_todo(user_id, todo_id, place) when is_binary(user_id) and is_binary(todo_id) do
    recent = DateTime.shift(DateTime.utc_now(), hour: -@recent_hours)

    listed =
      Repo.all(
        from t in Todo,
          where: t.user_id == ^user_id and (is_nil(t.completed_at) or t.completed_at >= ^recent),
          order_by: [asc: t.position, asc: t.id],
          select: {t.id, is_nil(t.completed_at)}
      )

    if List.keymember?(listed, todo_id, 0) do
      others = List.keydelete(listed, todo_id, 0)
      ids = others |> Enum.map(&elem(&1, 0)) |> List.insert_at(calculate_at(others, place), todo_id)

      Repo.update_all(
        from(t in Todo,
          join:
            p in fragment(
              "SELECT * FROM unnest(?::text[], ?::int[]) AS p(id, position)",
              ^ids,
              ^Enum.to_list(0..(length(ids) - 1))
            ),
          on: t.id == p.id,
          where: t.user_id == ^user_id,
          update: [set: [position: p.position, updated_at: ^DateTime.utc_now()]]
        ),
        []
      )

      :ok
    else
      :not_found
    end
  end

  defp calculate_at(others, :last), do: length(others)

  defp calculate_at(others, :after_open) do
    case others |> Enum.with_index() |> Enum.filter(fn {{_id, open?}, _index} -> open? end) |> List.last() do
      {_last_open, index} -> index + 1
      nil -> 0
    end
  end

  defp calculate_at(others, before_id) when is_binary(before_id) do
    Enum.find_index(others, fn {id, _open?} -> id == before_id end) || length(others)
  end
end
