defmodule RailWeb.Utils.MonotonicMs do
  @moduledoc false

  @doc """
  The monotonic clock in milliseconds, which a page measures a double click by.
  """
  def monotonic_ms, do: System.monotonic_time(:millisecond)
end
