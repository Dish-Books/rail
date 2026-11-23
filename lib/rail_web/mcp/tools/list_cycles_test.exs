defmodule RailWeb.Mcp.Tools.ListCyclesTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Projects

  setup do
    key = "MLC#{System.unique_integer([:positive])}"

    {:ok, local} =
      Projects.create_project(system_scope(), %{
        name: "Planned in cycles",
        github_repo: "example/#{key}",
        github_installation_id: 1,
        key: key,
        default_branch: "main",
        clone_path: "/tmp/#{key}"
      })

    %{local: local, scope: user_scope(project_ids: [local.id])}
  end

  test "names the running cycle as current and leaves ended cycles out unless asked", %{local: local, scope: scope} do
    # Cycle 1 runs Nov 10 to 23, then Cycle 2 from Nov 24.
    :ok = Issues.close_cycle_day(~D[2026-11-10])
    stub(Date, :utc_today, fn -> ~D[2026-11-25] end)

    assert {:ok,
            %{
              "current" => %{"number" => 2, "starts_on" => "2026-11-24", "status" => "running", "current" => true},
              "cycles" => [%{"number" => 2, "current" => true} | upcoming]
            }} = call_mcp_tool(scope, "list_cycles", %{"project" => local.key})

    assert Enum.all?(upcoming, &(&1["status"] == "upcoming" and &1["current"] == false))

    assert {:ok, %{"cycles" => [%{"number" => 1, "status" => "ended"}, %{"number" => 2} | _upcoming]}} =
             call_mcp_tool(scope, "list_cycles", %{"project" => local.name, "ended" => true})
  end

  test "a project with no cycles has no current one", %{local: local, scope: scope} do
    assert {:ok, %{"current" => nil, "cycles" => []}} = call_mcp_tool(scope, "list_cycles", %{"project" => local.key})
  end

  test "refuses a project the person cannot open", %{local: local, github_project: other} do
    assert {:error, "No project you can open has that key or name. Yours are: " <> _keys} =
             call_mcp_tool(user_scope(project_ids: [other.id]), "list_cycles", %{"project" => local.key})
  end
end
