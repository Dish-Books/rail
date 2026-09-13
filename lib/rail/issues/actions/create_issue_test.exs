defmodule Rail.Issues.Actions.CreateIssueTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects

  setup do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Create Issue Project 6101",
        github_repo: "org/create-issue-6101",
        github_installation_id: 6101,
        linear_workspace: %{
          name: "Create Issue Workspace",
          external_id: "lin_ws_create_issue",
          token: "lin_api_token_create_issue",
          webhook_secret: "whsec_create_issue"
        },
        linear_team_id: "team_cap_1",
        linear_team_key: "CI1",
        default_branch: "main",
        clone_path: "/tmp/repos/create-issue-6101",
        linear_state_ids: %{"triage" => "st_triage_1"}
      })

    %{project: project}
  end

  test "create_issue/2 opens the ticket in triage with the title and description given", %{
    project: %{id: project_id} = project
  } do
    Req.Test.expect(Rail.Linear, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert %{
               "input" => %{
                 "teamId" => "team_cap_1",
                 "title" => "Short title",
                 "description" => "More details here",
                 "stateId" => "st_triage_1",
                 "priority" => 2
               }
             } = Jason.decode!(body)["variables"]

      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{
              "id" => "lin_captured_1",
              "identifier" => "ENG-301",
              "title" => "Short title",
              "description" => "More details here",
              "priority" => 2,
              "state" => %{"id" => "st_triage_1", "name" => "Triage", "type" => "triage"},
              "branchName" => "eng-301-branch",
              "url" => "https://linear.app/issue/ENG-301"
            }
          }
        }
      })
    end)

    assert {:ok,
            %Issue{
              id: "iss_" <> _id,
              project_id: ^project_id,
              external_id: "lin_captured_1",
              identifier: "ENG-301",
              title: "Short title",
              description: "More details here",
              priority: :high,
              state: :triage,
              state_name: "Triage",
              branch_name: "eng-301-branch",
              url: "https://linear.app/issue/ENG-301"
            }} =
             Issues.create_issue(project, %{title: "Short title", description: "More details here", priority: :high})
  end

  test "create_issue/2 defaults to medium priority and sends Linear none", %{project: project} do
    Req.Test.expect(Rail.Linear, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      input = Jason.decode!(body)["variables"]["input"]

      refute Map.has_key?(input, "priority")
      refute Map.has_key?(input, "description")

      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_captured_2", "identifier" => "ENG-302", "title" => "No priority"}
          }
        }
      })
    end)

    assert {:ok, %Issue{priority: :medium, state: :triage, state_name: "Triage"}} =
             Issues.create_issue(project, %{title: "No priority"})
  end

  test "create_issue/2 refuses a priority that is not one of the known ones", %{project: project} do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_captured_3", "identifier" => "ENG-303", "title" => "Bad priority"}
          }
        }
      })
    end)

    assert {:error, %Ecto.Changeset{} = changeset} =
             Issues.create_issue(project, %{title: "Bad priority", priority: "invalid_priority"})

    assert %{priority: ["is invalid"]} = errors_on(changeset)
  end

  test "create_issue/2 returns an error when Linear does not create it", %{project: project} do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"issueCreate" => %{"success" => false}}})
    end)

    assert {:error, {:linear_mutation_failed, "issueCreate"}} =
             Issues.create_issue(project, %{title: "Failing", description: "Failing"})
  end

  test "create_issue/2 returns Linear's error", %{project: project} do
    Req.Test.expect(Rail.Linear, fn conn ->
      conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => "down"})
    end)

    assert {:error, {:linear_api_error, 500, _body}} = Issues.create_issue(project, %{title: "Failing"})
  end
end
