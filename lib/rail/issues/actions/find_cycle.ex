defmodule Rail.Issues.Actions.FindCycle do
  @moduledoc """
  The cycle a person names for a ticket the way an MCP tool takes it: a word or a number rather than an id.
  """

  alias Rail.Issues
  alias Rail.Projects.Schemas.Project

  @doc """
  Resolves `wanted` among `project`'s cycles: `"current"`, `"next"`, an open cycle's number, or `"none"`, in any case.
  Returns `{:ok, cycle_id}`, or `{:ok, nil}` for none. Anything else, an ended cycle among them, is
  `{:error, {:invalid, :cycle, message}}` naming the open cycles.
  """
  def find_cycle(%Project{} = project, wanted) do
    wanted = wanted |> to_string() |> String.trim() |> String.downcase()
    {:ok, %{cycles: cycles}} = Issues.get_cycles(project)
    open = Enum.reject(cycles, &(&1.status == :ended))
    current_index = Enum.find_index(cycles, & &1.current)

    found =
      case {wanted, Integer.parse(wanted)} do
        {"none", _number} -> {:set, nil}
        {"current", _number} -> current_index && {:set, Enum.at(cycles, current_index).id}
        {"next", _number} -> next_cycle(cycles, current_index)
        {_named, {number, ""}} -> Enum.find_value(open, &(&1.number == number && {:set, &1.id}))
        _unknown -> nil
      end

    case found do
      {:set, cycle_id} ->
        {:ok, cycle_id}

      nil ->
        {:error,
         {:invalid, :cycle,
          "is not current, next, none or an open cycle's number: " <> Enum.map_join(open, ", ", &to_string(&1.number))}}
    end
  end

  defp next_cycle(cycles, current_index) when is_integer(current_index) do
    case Enum.at(cycles, current_index + 1) do
      %{id: id} -> {:set, id}
      nil -> nil
    end
  end

  defp next_cycle(_cycles, nil), do: nil
end
