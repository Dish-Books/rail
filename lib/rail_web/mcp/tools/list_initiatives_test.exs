defmodule RailWeb.Mcp.Tools.ListInitiativesTest do
  use Rail.DataCase, async: true

  alias Rail.Initiatives
  alias Rail.Issues
  alias Rail.Projects

  @done %{id: "done", name: "Done", state: :done}

  setup do
    [local, other] =
      for name <- ["Grouped", "Hidden"] do
        key = "MLI#{System.unique_integer([:positive])}"

        {:ok, project} =
          Projects.create_project(system_scope(), %{
            name: name,
            github_repo: "example/#{key}",
            github_installation_id: 1,
            key: key,
            default_branch: "main",
            clone_path: "/tmp/#{key}"
          })

        project
      end

    {:ok, _hidden} = Initiatives.create_initiative(system_scope(), other, %{name: "Not yours"})
    %{local: local, other: other, scope: user_scope(project_ids: [local.id])}
  end

  test "lists a project's initiatives with their progress and expected dates", %{
    local: %{key: key} = local,
    scope: scope
  } do
    stub(Date, :utc_today, fn -> ~D[2026-11-23] end)

    {:ok, %{id: credo_id} = credo} =
      Initiatives.create_initiative(system_scope(), local, %{name: "Credo exclusions", expected_on: ~D[2026-12-12]})

    {:ok, _payroll} = Initiatives.create_initiative(system_scope(), local, %{name: "Payroll v2"})

    for status <- [@done, nil, nil] do
      {:ok, issue} = Issues.create_issue(system_scope(), local, %{title: "Credo work"})
      {:ok, issue} = Issues.set_issue_initiative(system_scope(), issue, credo.id)
      if status, do: {:ok, _issue} = Issues.set_issue_status(system_scope(), issue, status)
    end

    url = "#{RailWeb.Endpoint.url()}/initiatives/#{credo_id}"

    assert {:ok,
            %{
              "initiatives" => [
                %{
                  "name" => "Credo exclusions",
                  "project" => ^key,
                  "percent_done" => 33,
                  "done" => 1,
                  "total" => 3,
                  "expected_on" => "2026-12-12",
                  "due" => "19 days left",
                  "url" => ^url
                },
                %{"name" => "Payroll v2", "percent_done" => 0, "total" => 0, "expected_on" => nil, "due" => nil}
              ]
            }} = call_mcp_tool(scope, "list_initiatives", %{"project" => local.key})
  end

  test "with no project lists every project the person can open, and none they cannot", %{local: local, scope: scope} do
    {:ok, _mine} = Initiatives.create_initiative(system_scope(), local, %{name: "Mine"})

    assert {:ok, %{"initiatives" => [%{"name" => "Mine"}]}} = call_mcp_tool(scope, "list_initiatives", %{})
  end

  test "refuses a project the person cannot open", %{other: other, scope: scope} do
    assert {:error, "No project you can open has that key or name. Yours are: " <> _keys} =
             call_mcp_tool(scope, "list_initiatives", %{"project" => other.key})
  end
end
