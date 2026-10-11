defmodule RailWeb.Utils.CalculateCriteria do
  @moduledoc false

  @doc """
  Counts a ticket's acceptance criteria: the list items under the heading that names them, up to the next heading.
  """
  def calculate_criteria(description) do
    description
    |> String.split("\n")
    |> Enum.drop_while(&(not Regex.match?(~r/^#+\s+acceptance criteria/i, &1)))
    |> Enum.drop(1)
    |> Enum.take_while(&(not String.starts_with?(&1, "#")))
    |> Enum.count(&Regex.match?(~r/^\s?([-*+]|\d+\.)\s+\S/, &1))
  end
end
