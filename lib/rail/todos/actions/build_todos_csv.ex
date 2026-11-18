defmodule Rail.Todos.Actions.BuildTodosCsv do
  @moduledoc false

  import Rail.Todos.Utils.CalculateDayBounds

  alias Rail.Todos
  alias Rail.Todos.Schemas.Todo

  @header ["To-do", "Link", "Added", "Checked off"]
  # Excel reads a file without it as the system's code page, not UTF-8.
  @bom <<0xEF, 0xBB, 0xBF>>

  @doc """
  Returns `{filename, csv}`: the to-dos the scope's user checked off today in `time_zone`, one row each.
  """
  def build_todos_csv(scope, time_zone, base_url) when is_binary(base_url) do
    now = DateTime.utc_now()
    {zone, date, _from, _to} = calculate_day_bounds(time_zone, now)
    base_url = String.trim_trailing(base_url, "/")
    todos = Todos.list_todos(scope, checked_off_today: zone, now: now)
    rows = [@header | Enum.map(todos, &row(&1, zone, base_url))]
    csv = Enum.map_join(rows, "", fn cells -> Enum.map_join(cells, ",", &cell/1) <> "\r\n" end)
    {"to-dos-#{Date.to_iso8601(date)}.csv", @bom <> csv}
  end

  defp row(%Todo{} = todo, zone, base_url) do
    link =
      cond do
        is_nil(todo.url) -> ""
        String.starts_with?(todo.url, "/") -> base_url <> todo.url
        true -> todo.url
      end

    [todo.body, link, local_time(todo.inserted_at, zone), local_time(todo.completed_at, zone)]
  end

  defp local_time(moment, zone), do: moment |> DateTime.shift_zone!(zone) |> Calendar.strftime("%Y-%m-%d %H:%M")

  # A spreadsheet runs a cell that starts with one of these as a formula.
  defp cell(value) do
    value = if String.starts_with?(value, ["=", "+", "-", "@", "\t", "\r"]), do: "'" <> value, else: value
    ~s("#{String.replace(value, ~s("), ~s(""))}")
  end
end
