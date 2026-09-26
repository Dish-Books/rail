defmodule Rail.Projects.Actions.UpdateProjectTest do
  use Rail.DataCase, async: true

  alias Rail.Projects
  alias Rail.Projects.Schemas.LinearWorkspace
  alias Rail.Projects.Schemas.Project
  alias Rail.Scope

  test "admin updates project successfully" do
    admin_scope = Scope.for_user(%{admin: true})
    repo = "example/update-repo-#{System.unique_integer([:positive])}"

    assert {:ok, %Project{id: project_id} = project} =
             Projects.create_project(admin_scope, %{
               name: "Original Name",
               github_repo: repo,
               github_installation_id: 55_667,
               linear_team_key: "ORIG",
               default_branch: "main",
               clone_path: "/tmp/orig"
             })

    assert {:ok, %Project{id: ^project_id, name: "Updated Name", active: false, default_branch: "develop"}} =
             Projects.update_project(admin_scope, project, %{
               name: "Updated Name",
               active: false,
               default_branch: "develop"
             })
  end

  test "moving a project to another workspace looks its team up through that one" do
    admin_scope = Scope.for_user(%{admin: true})

    Req.Test.expect(Rail.Linear, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer lin_api_old"]
      Req.Test.json(conn, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "lin_team_old"}]}}})
    end)

    workspace = fn key ->
      {:ok, workspace} =
        Projects.create_linear_workspace(admin_scope, %{
          name: key,
          external_id: "lin_org_#{key}",
          token: "lin_api_#{key}",
          webhook_secret: "wh"
        })

      workspace
    end

    %LinearWorkspace{id: old_id} = workspace.("old")
    %LinearWorkspace{id: new_id} = workspace.("new")

    assert {:ok, %Project{linear_team_id: "lin_team_old"} = project} =
             Projects.create_project(admin_scope, %{
               name: "Moving Project",
               github_repo: "example/moving-#{System.unique_integer([:positive])}",
               github_installation_id: 55_668,
               linear_team_key: "MOV",
               default_branch: "main",
               clone_path: "/tmp/move",
               linear_workspace_id: old_id
             })

    Req.Test.expect(Rail.Linear, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer lin_api_new"]
      Req.Test.json(conn, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "lin_team_new"}]}}})
    end)

    assert {:ok, %Project{linear_team_id: "lin_team_new", linear_workspace: %LinearWorkspace{id: ^new_id}}} =
             Projects.update_project(admin_scope, project, %{linear_workspace_id: new_id})
  end

  test "returns validation error changeset for invalid attributes" do
    admin_scope = Scope.for_user(%{admin: true})
    repo = "example/invalid-update-repo-#{System.unique_integer([:positive])}"

    assert {:ok, %Project{} = project} =
             Projects.create_project(admin_scope, %{
               name: "Valid Project",
               github_repo: repo,
               github_installation_id: 55_669,
               linear_team_key: "INV",
               default_branch: "main",
               clone_path: "/tmp/inv"
             })

    assert {:error, changeset} = Projects.update_project(admin_scope, project, %{name: ""})
    assert %{name: ["can't be blank"]} = errors_on(changeset)
  end

  test "rejects non-admin user scope" do
    admin_scope = Scope.for_user(%{admin: true})
    repo = "example/unauth-update-repo-#{System.unique_integer([:positive])}"

    assert {:ok, %Project{} = project} =
             Projects.create_project(admin_scope, %{
               name: "Project to Guard",
               github_repo: repo,
               github_installation_id: 55_670,
               linear_team_key: "GRD",
               default_branch: "main",
               clone_path: "/tmp/guard"
             })

    user_scope = Scope.for_user(%{admin: false})
    assert {:error, :not_authorized} = Projects.update_project(user_scope, project, %{name: "Hacked"})
  end

  test "rejects nil scope" do
    admin_scope = Scope.for_user(%{admin: true})
    repo = "example/nil-update-repo-#{System.unique_integer([:positive])}"

    assert {:ok, %Project{} = project} =
             Projects.create_project(admin_scope, %{
               name: "Project to Guard Nil",
               github_repo: repo,
               github_installation_id: 55_671,
               linear_team_key: "GRDN",
               default_branch: "main",
               clone_path: "/tmp/guard_nil"
             })

    assert {:error, :not_authorized} = Projects.update_project(nil, project, %{name: "Hacked"})
  end

  test "a worktree setup script has to be a path inside the repository" do
    admin_scope = Scope.for_user(%{admin: true})

    assert {:ok, %Project{} = project} =
             Projects.create_project(admin_scope, %{
               name: "Setup Project",
               github_repo: "example/setup-repo-#{System.unique_integer([:positive])}",
               github_installation_id: 55_670,
               linear_team_key: "SET",
               default_branch: "main",
               clone_path: "/tmp/set"
             })

    assert {:ok, %Project{worktree_setup_script: "scripts/setup-worktree.sh"}} =
             Projects.update_project(admin_scope, project, %{worktree_setup_script: "scripts/setup-worktree.sh"})

    for outside <- ["/usr/local/bin/setup", "../elsewhere/setup.sh"] do
      assert {:error, changeset} = Projects.update_project(admin_scope, project, %{worktree_setup_script: outside})
      assert %{worktree_setup_script: ["must be a path inside the repository"]} = errors_on(changeset)
    end
  end

  test "names the user whose MCP connections triage uses", %{project: project} do
    unique = System.unique_integer([:positive])

    {:ok, %{id: user_id}} =
      Rail.Users.register_oauth_user(%{github_id: "tri_#{unique}", login: "tri_#{unique}", email: "tri_#{unique}@x.com"})

    assert {:ok, %Project{triage_user_id: ^user_id}} =
             Projects.update_project(system_scope(), project, %{"triage_user_id" => user_id})
  end
end
