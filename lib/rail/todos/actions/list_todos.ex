defmodule Rail.Todos.Actions.ListTodos do
  @moduledoc false

  import Ecto.Query
  import Rail.Todos.Utils.CalculateDayBounds

  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Todos.Schemas.Todo
  alias Rail.Users.Schemas.User

  @doc """
  The scope's user's open to-dos in their order. `checked_off_today: time_zone` lists the ones checked off
  on the day `now:` falls on in that zone instead, in the order they were checked off.
  """
  def list_todos(%Scope{user: %User{id: user_id}}, opts) do
    Todo
    |> where([t], t.user_id == ^user_id)
    |> filter_state(Keyword.fetch(opts, :checked_off_today), Keyword.get_lazy(opts, :now, &DateTime.utc_now/0))
    |> Repo.all()
  end

  def list_todos(_scope, _opts), do: []

  defp filter_state(query, {:ok, time_zone}, now) do
    {_zone, _date, from, to} = calculate_day_bounds(time_zone, now)

    query
    |> where([t], t.completed_at >= ^from and t.completed_at < ^to)
    |> order_by([t], asc: t.completed_at, asc: t.id)
  end

  defp filter_state(query, :error, _now) do
    query
    |> where([t], is_nil(t.completed_at))
    |> order_by([t], asc: t.position, asc: t.id)
  end
end
