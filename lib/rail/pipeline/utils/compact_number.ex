defmodule Rail.Pipeline.Utils.CompactNumber do
  @moduledoc false

  @doc """
  Abbreviates a count for a log line or a metadata bar, where the magnitude is
  what a reader wants and the exact figure is noise.
  """
  def compact_number(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 2)}M"
  def compact_number(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  def compact_number(n), do: "#{n}"
end
