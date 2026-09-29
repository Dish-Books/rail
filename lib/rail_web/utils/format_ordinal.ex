defmodule RailWeb.Utils.FormatOrdinal do
  @moduledoc false

  @doc """
  Formats a place in line: `"1st"`, `"2nd"`, `"11th"`, `"23rd"`.
  """
  def format_ordinal(position) when is_integer(position) do
    suffix =
      cond do
        rem(position, 100) in 11..13 -> "th"
        rem(position, 10) == 1 -> "st"
        rem(position, 10) == 2 -> "nd"
        rem(position, 10) == 3 -> "rd"
        true -> "th"
      end

    "#{position}#{suffix}"
  end
end
