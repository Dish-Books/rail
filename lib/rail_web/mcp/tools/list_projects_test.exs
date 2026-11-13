defmodule RailWeb.Mcp.Tools.ListProjectsTest do
  use Rail.DataCase, async: true

  test "lists only the projects the person can open, with their keys", %{
    project: %{key: project_key, name: project_name} = project,
    github_project: github
  } do
    assert {:ok, %{"projects" => [%{"key" => ^project_key, "name" => ^project_name, "tracker" => "Linear"}]}} =
             call_mcp_tool(user_scope(project_ids: [project.id]), "list_projects", %{})

    refute Enum.any?(
             elem(call_mcp_tool(user_scope(project_ids: [project.id]), "list_projects", %{}), 1)["projects"],
             &(&1["key"] == github.key)
           )
  end
end
