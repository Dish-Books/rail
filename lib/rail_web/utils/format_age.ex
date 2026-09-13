defmodule RailWeb.Utils.FormatAge do
  @moduledoc false

  @doc """
  Formats how long something has been so, coarsely: `"2d 3h"`, `"2h 14m"`,
  `"14m"`, `"<1m"`. Unlike a duration it never counts seconds, because it is
  read at a glance and does not tick.
  """
  def format_age(seconds) when is_integer(seconds) do
    total = max(seconds, 0)
    days = div(total, 86_400)
    hours = total |> rem(86_400) |> div(3600)
    minutes = total |> rem(3600) |> div(60)

    cond do
      days > 0 -> "#{days}d #{hours}h"
      hours > 0 -> "#{hours}h #{minutes}m"
      minutes > 0 -> "#{minutes}m"
      true -> "<1m"
    end
  end
end
