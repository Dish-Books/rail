defmodule Rail.Projects.Actions.FindProject do
  @moduledoc false

  alias Rail.Projects
  alias Rail.Projects.Schemas.Project

  @doc """
  The project of the scope's own that `key_or_name` names, by key first, then by name, ignoring case. No match, or two
  projects with that name, is `{:error, {:not_found, keys}}` with the keys the scope can use.
  """
  def find_project(scope, key_or_name) when is_binary(key_or_name) do
    projects = Projects.list_projects(scope)
    wanted = key_or_name |> String.trim() |> String.downcase()

    case {Enum.filter(projects, &(String.downcase(&1.key) == wanted)),
          Enum.filter(projects, &(String.downcase(&1.name) == wanted))} do
      {[%Project{} = project | _same_key_other_case], _by_name} -> {:ok, project}
      {[], [%Project{} = project]} -> {:ok, project}
      _none_or_many -> {:error, {:not_found, projects |> Enum.map(& &1.key) |> Enum.sort()}}
    end
  end
end
