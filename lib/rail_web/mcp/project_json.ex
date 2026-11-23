defmodule RailWeb.Mcp.ProjectJSON do
  @moduledoc false

  alias Rail.Projects.Schemas.Project

  def index(%{projects: projects}), do: %{projects: Enum.map(projects, &data/1)}

  defp data(%Project{} = project), do: %{key: project.key, name: project.name}
end
