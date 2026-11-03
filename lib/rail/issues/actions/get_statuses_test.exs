defmodule Rail.Issues.Actions.GetStatusesTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Projects.Schemas.Project

  test "a Linear team's own statuses come in workflow order, custom ones and In Review included", %{project: project} do
    Req.Test.expect(Rail.Linear, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert %{"query" => query} = Jason.decode!(body)
      assert query =~ "name"

      Req.Test.json(conn, %{
        "data" => %{
          "teams" => %{
            "nodes" => [
              %{
                "states" => %{
                  "nodes" => [
                    %{"id" => "st_done", "name" => "Done", "type" => "completed", "position" => 5.0},
                    %{"id" => "st_review", "name" => "In Review", "type" => "started", "position" => 3.0},
                    %{"id" => "st_deploy", "name" => "Waiting on deploy", "type" => "started", "position" => 2.0},
                    %{"id" => "st_b_tie", "name" => "Second", "type" => "backlog", "position" => 0.0},
                    %{"id" => "st_a_tie", "name" => "First", "type" => "backlog", "position" => 0.0},
                    %{"id" => "st_triage", "name" => "Triage", "type" => "triage", "position" => 0.0},
                    %{"id" => "st_todo", "name" => "Todo", "type" => "unstarted", "position" => 1.0},
                    %{"id" => "st_canceled", "name" => "Canceled", "type" => "canceled", "position" => 6.0}
                  ]
                }
              }
            ]
          }
        }
      })
    end)

    assert {:ok,
            [
              %{id: "st_triage", name: "Triage", state: :triage},
              %{id: "st_a_tie", name: "First", state: :backlog},
              %{id: "st_b_tie", name: "Second", state: :backlog},
              %{id: "st_todo", name: "Todo", state: :backlog},
              %{id: "st_deploy", name: "Waiting on deploy", state: :in_progress},
              %{id: "st_review", name: "In Review", state: :in_review},
              %{id: "st_done", name: "Done", state: :done},
              %{id: "st_canceled", name: "Canceled", state: :canceled}
            ]} = Issues.get_statuses(system_scope(), project)
  end

  test "a Linear project with no team answers with an error, so the menu is never empty", %{
    project: %Project{} = project
  } do
    assert {:error, :linear_team_not_found} =
             Issues.get_statuses(system_scope(), %{project | linear_team_id: nil})
  end

  test "a team Linear no longer knows is an error", %{project: project} do
    Req.Test.expect(Rail.Linear, &Req.Test.json(&1, %{"data" => %{"teams" => %{"nodes" => []}}}))

    assert {:error, :linear_team_not_found} = Issues.get_statuses(system_scope(), project)
  end

  test "Linear not answering is an error", %{project: project} do
    Req.Test.expect(Rail.Linear, &Plug.Conn.send_resp(&1, 503, "down"))

    assert {:error, {:linear_api_error, 503, _body}} = Issues.get_statuses(system_scope(), project)
  end

  test "a GitHub project offers Rail's statuses in the order an issue moves through them", %{github_project: project} do
    assert {:ok,
            [
              %{id: "triage", name: "Triage", state: :triage},
              %{id: "backlog", name: "Backlog", state: :backlog},
              %{id: "todo", name: "Todo", state: :todo},
              %{id: "in_progress", name: "In Progress", state: :in_progress},
              %{id: "in_review", name: "In Review", state: :in_review},
              %{id: "done", name: "Done", state: :done},
              %{id: "canceled", name: "Canceled", state: :canceled},
              %{id: "duplicate", name: "Duplicate", state: :duplicate}
            ]} = Issues.get_statuses(system_scope(), project)
  end

  test "a scope without the project is refused before any request", %{project: project} do
    assert {:error, :not_found} = Issues.get_statuses(temp_user_scope(), project)
  end
end
