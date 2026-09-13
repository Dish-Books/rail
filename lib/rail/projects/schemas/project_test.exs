defmodule Rail.Projects.Schemas.ProjectTest do
  use Rail.DataCase, async: true

  alias Rail.Projects.Schemas.LinearWorkspace
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo

  test "changeset validates required fields" do
    changeset = Project.changeset(%Project{}, %{})

    assert %{
             name: ["can't be blank"],
             github_repo: ["can't be blank"],
             github_installation_id: ["can't be blank"],
             default_branch: ["can't be blank"],
             linear_team_key: ["can't be blank"],
             clone_path: ["can't be blank"]
           } = errors_on(changeset)
  end

  test "changeset validates default_branch cannot be blank" do
    changeset1 = Project.changeset(%Project{}, %{"default_branch" => ""})
    assert %{default_branch: ["can't be blank"]} = errors_on(changeset1)

    changeset2 = Project.changeset(%Project{}, %{default_branch: ""})
    assert %{default_branch: ["can't be blank"]} = errors_on(changeset2)

    changeset3 = Project.changeset(%Project{}, %{"default_branch" => nil})
    assert %{default_branch: ["can't be blank"]} = errors_on(changeset3)
  end

  test "changeset accepts valid attributes and sets defaults" do
    attrs = %{
      name: "Rail Project",
      github_repo: "example/rail-app",
      github_installation_id: 12_345,
      default_branch: "main",
      linear_team_key: "RAIL",
      clone_path: "/tmp/rail"
    }

    changeset = Project.changeset(%Project{}, attrs)
    assert changeset.valid?
    assert get_field(changeset, :default_branch) == "main"
    assert get_field(changeset, :active) == true
  end

  test "changeset enforces uniqueness on github_repo" do
    repo = "example/repo-#{System.unique_integer([:positive])}"

    base_attrs = %{
      name: "Project 1",
      github_repo: repo,
      github_installation_id: 99_001,
      default_branch: "main",
      linear_team_key: "P1",
      clone_path: "/tmp/p1"
    }

    assert {:ok, %Project{github_repo: ^repo}} =
             %Project{}
             |> Project.changeset(base_attrs)
             |> Repo.insert()

    assert {:error, changeset} =
             %Project{}
             |> Project.changeset(%{base_attrs | name: "Project 2"})
             |> Repo.insert()

    assert %{github_repo: ["has already been taken"]} = errors_on(changeset)
  end

  test "has one linear_workspace created through the project changeset" do
    ext_id = "lin_ext_#{System.unique_integer([:positive])}"
    repo = "example/repo-ws-#{System.unique_integer([:positive])}"

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "lin_team_id"}]}}})
    end)

    assert {:ok, %Project{id: project_id, linear_workspace: %LinearWorkspace{id: workspace_id}}} =
             %Project{}
             |> Project.changeset(%{
               name: "Project with WS",
               github_repo: repo,
               github_installation_id: 99_003,
               linear_workspace: %{
                 name: "Workspace For Project",
                 external_id: ext_id,
                 token: "tok_proj",
                 webhook_secret: "wh_proj"
               },
               default_branch: "main",
               linear_team_key: "PWS",
               clone_path: "/tmp/pws"
             })
             |> Repo.insert()

    assert %LinearWorkspace{id: ^workspace_id, project_id: ^project_id} =
             Repo.get_by(LinearWorkspace, project_id: project_id)
  end

  test "looks the Linear team and its states up from the key, through the workspace, as the row is written" do
    Req.Test.expect(Rail.Linear, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer lin_api_team_lookup"]
      assert %{"teamKey" => "DIS"} = Jason.decode!(body)["variables"]

      Req.Test.json(conn, %{
        "data" => %{
          "teams" => %{
            "nodes" => [
              %{
                "id" => "lin_team_dis",
                "states" => %{
                  "nodes" => [
                    %{"id" => "st_todo_late", "type" => "unstarted", "position" => 3},
                    %{"id" => "st_triage", "type" => "triage", "position" => 0},
                    %{"id" => "st_todo", "type" => "unstarted", "position" => 2},
                    %{"id" => "st_started", "type" => "started", "position" => 4},
                    %{"id" => "st_done", "type" => "completed", "position" => 5}
                  ]
                }
              }
            ]
          }
        }
      })
    end)

    changeset =
      Project.changeset(%Project{}, %{
        name: "Team Lookup",
        github_repo: "example/team-lookup",
        github_installation_id: 99_010,
        default_branch: "main",
        linear_team_key: "DIS",
        clone_path: "/tmp/team-lookup",
        linear_workspace: %{
          name: "Team Lookup Workspace",
          external_id: "lin_org_team_lookup",
          token: "lin_api_team_lookup",
          webhook_secret: "whsec_team_lookup"
        }
      })

    # Building the changeset asks Linear nothing; only writing it does.
    # A type with several states resolves to the first of them.
    state_ids = %{"triage" => "st_triage", "todo" => "st_todo", "in_progress" => "st_started", "done" => "st_done"}

    assert {:ok, %Project{linear_team_id: "lin_team_dis", linear_state_ids: ^state_ids} = project} =
             Repo.insert(changeset)

    # A change that leaves the key and the workspace alone asks again for nothing.
    assert {:ok, %Project{linear_team_id: "lin_team_dis"}} =
             project |> Project.changeset(%{name: "Renamed"}) |> Repo.update()
  end

  test "a key Linear has no team for is an error on the key and nothing is written" do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"teams" => %{"nodes" => []}}})
    end)

    assert {:error, changeset} =
             %Project{}
             |> Project.changeset(%{
               name: "Unknown Team",
               github_repo: "example/unknown-team",
               github_installation_id: 99_011,
               default_branch: "main",
               linear_team_key: "NOPE",
               clone_path: "/tmp/unknown-team",
               linear_workspace: %{
                 name: "Unknown Team Workspace",
                 external_id: "lin_org_unknown_team",
                 token: "lin_api_unknown_team",
                 webhook_secret: "whsec_unknown_team"
               }
             })
             |> Repo.insert()

    assert %{linear_team_key: ["no Linear team has this key"]} = errors_on(changeset)
    refute Repo.get_by(Project, github_repo: "example/unknown-team")
  end

  test "a project with no workspace yet has no team id to look up" do
    # No Linear stub is queued, so a request would raise.
    assert {:ok, %Project{linear_team_id: nil}} =
             %Project{}
             |> Project.changeset(%{
               name: "No Workspace",
               github_repo: "example/no-workspace",
               github_installation_id: 99_012,
               default_branch: "main",
               linear_team_key: "DIS",
               clone_path: "/tmp/no-workspace"
             })
             |> Repo.insert()
  end
end
