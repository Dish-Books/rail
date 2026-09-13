defmodule RailWeb.Utils.FormatDuration do
  @moduledoc false

  @doc """
  Formats a number of seconds as a duration: `"1h 2m 3s"`, `"2m 3s"`, `"3s"`.
  """
  def format_duration(nil), do: ""
  def format_duration(seconds) when is_float(seconds), do: format_duration(round(seconds))

  def format_duration(seconds) when is_integer(seconds) do
    total = max(seconds, 0)
    hours = div(total, 3600)
    minutes = total |> rem(3600) |> div(60)
    secs = rem(total, 60)

    cond do
      hours > 0 -> "#{hours}h #{minutes}m #{secs}s"
      minutes > 0 -> "#{minutes}m #{secs}s"
      true -> "#{secs}s"
    end
  end
end
