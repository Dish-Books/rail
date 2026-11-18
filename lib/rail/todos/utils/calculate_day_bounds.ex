defmodule Rail.Todos.Utils.CalculateDayBounds do
  @moduledoc """
  The day `now` falls on in a time zone the browser reported, as its date and its two midnights.
  """

  @doc """
  Returns `{time_zone, date, from, to}`, with a missing or unknown zone read as UTC.
  """
  def calculate_day_bounds(time_zone, %DateTime{} = now) do
    {zone, local} =
      case is_binary(time_zone) && DateTime.shift_zone(now, time_zone) do
        {:ok, local} -> {time_zone, local}
        _missing_or_unknown -> {"Etc/UTC", DateTime.shift_zone!(now, "Etc/UTC")}
      end

    date = DateTime.to_date(local)
    {zone, date, midnight(date, zone), midnight(Date.add(date, 1), zone)}
  end

  # A clock change can skip midnight or repeat it; the day starts at its first moment either way.
  defp midnight(date, zone) do
    case DateTime.new(date, ~T[00:00:00], zone) do
      {:ok, moment} -> moment
      {:gap, _before, just_after} -> just_after
      {:ambiguous, first, _second} -> first
    end
  end
end
