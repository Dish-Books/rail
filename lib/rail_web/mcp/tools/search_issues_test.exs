defmodule RailWeb.Mcp.Tools.SearchIssuesTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects

  setup do
    key = "MSR#{System.unique_integer([:positive])}"

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Searched by meaning",
        github_repo: "example/#{key}",
        github_installation_id: 1,
        tracker: :local,
        key: key,
        default_branch: "main",
        clone_path: "/tmp/#{key}"
      })

    %{local: project, scope: user_scope(project_ids: [project.id])}
  end

  test "returns the nearest tickets of one project", %{local: local, scope: scope} do
    {:ok, %Issue{id: near_id, identifier: near}} = Issues.create_issue(system_scope(), local, %{title: "Rows wait"})
    {:ok, %Issue{id: far_id, identifier: far}} = Issues.create_issue(system_scope(), local, %{title: "Colors"})

    for {id, components} <- [{near_id, [1.0]}, {far_id, [0.0, 1.0]}] do
      Repo.update_all(from(i in Issue, where: i.id == ^id), set: [embedding: Pgvector.new(vector(components))])
    end

    stub_vertex(%{"waiting" => vector([1.0])})

    assert {:ok,
            %{
              "issues" => [
                %{"identifier" => ^near, "title" => "Rows wait", "status" => "Triage", "priority" => "medium"},
                %{"identifier" => ^far}
              ]
            }} = call_mcp_tool(scope, "search_issues", %{"project" => local.key, "query" => "rows waiting too long"})
  end

  test "says the search could not run rather than that nothing matched", %{local: local, scope: scope} do
    stub_vertex_down()

    assert {:error, "Ticket search is unavailable right now, so nothing was searched."} =
             call_mcp_tool(scope, "search_issues", %{"project" => local.key, "query" => "anything"})
  end

  test "a project the person cannot open is not found", %{local: local} do
    assert {:error, "You can't open any project in Rail."} =
             call_mcp_tool(user_scope(project_ids: []), "search_issues", %{"project" => local.key, "query" => "x"})
  end
end
