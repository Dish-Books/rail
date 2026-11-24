defmodule Rail.Initiatives.Actions.FindInitiative do
  @moduledoc "The initiative a person names for a ticket the way an MCP tool takes it: a name rather than an id."

  alias Rail.Initiatives
  alias Rail.Initiatives.Schemas.Initiative
  alias Rail.Projects.Schemas.Project
  alias Rail.Scope

  @doc """
  Resolves `name` among `project`'s initiatives, ignoring case and surrounding spaces. Anything else is
  `{:error, {:invalid, :initiative, message}}` naming the project's initiatives.
  """
  def find_initiative(%Scope{} = scope, %Project{id: project_id, key: key}, name) when is_binary(name) do
    initiatives = Initiatives.list_initiatives(scope, project_id: project_id, sort: :name)
    wanted = name |> String.trim() |> String.downcase()

    found = Enum.find(initiatives, &(String.downcase(&1.name) == wanted))

    cond do
      match?(%Initiative{}, found) -> {:ok, found}
      initiatives == [] -> {:error, {:invalid, :initiative, "names none: #{key} has no initiatives"}}
      true -> {:error, {:invalid, :initiative, "is not one in #{key}: " <> Enum.map_join(initiatives, ", ", & &1.name)}}
    end
  end
end
