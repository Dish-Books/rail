defmodule RailWeb.Mcp.CycleJSON do
  @moduledoc false

  # The current cycle is named on its own too, so Claude need not search the list for it.
  def index(%{cycles: cycles}) do
    %{current: cycles |> Enum.find(& &1.current) |> data(), cycles: Enum.map(cycles, &data/1)}
  end

  defp data(nil), do: nil

  defp data(cycle) do
    %{
      number: cycle.number,
      starts_on: cycle.starts_on,
      ends_on: cycle.ends_on,
      status: cycle.status,
      current: cycle.current
    }
  end
end
