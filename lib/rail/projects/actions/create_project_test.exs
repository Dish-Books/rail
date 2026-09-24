defmodule Rail.Projects.Actions.CreateProjectTest do
  use Rail.DataCase, async: true

  alias Rail.Projects
  alias Rail.Projects.Schemas.LinearWorkspace
  alias Rail.Projects.Schemas.Project
  alias Rail.Scope

  test "creates a project with admin scope" do
    scope = Scope.for_user(%{admin: true})
    repo = "example/repo-#{System.unique_integer([:positive])}"

    attrs = %{
      name: "Rail Admin Project",
      github_repo: repo,
      github_installation_id: 12_345,
      linear_team_key: "RAIL",
      default_branch: "main",
      clone_path: "/tmp/rail"
    }

    assert {:ok, %Project{name: "Rail Admin Project", github_repo: ^repo, default_branch: "main"}} =
             Projects.create_project(scope, attrs)
  end

  test "creates a project with system scope" do
    scope = Scope.for_system()
    repo = "example/system-repo-#{System.unique_integer([:positive])}"

    attrs = %{
      name: "System Project",
      github_repo: repo,
      github_installation_id: 67_890,
      linear_team_key: "SYS",
      default_branch: "main",
      clone_path: "/tmp/sys"
    }

    assert {:ok, %Project{name: "System Project", github_repo: ^repo}} =
             Projects.create_project(scope, attrs)
  end

  test "returns validation error changeset for missing required fields" do
    scope = Scope.for_user(%{admin: true})

    assert {:error, changeset} = Projects.create_project(scope, %{})

    assert %{
             name: ["can't be blank"],
             github_repo: ["can't be blank"],
             github_installation_id: ["can't be blank"],
             linear_team_key: ["can't be blank"],
             clone_path: ["can't be blank"]
           } = errors_on(changeset)
  end

  test "projects link to a saved Linear workspace by id, and an unknown id is an error on it" do
    scope = Scope.for_user(%{admin: true})

    Req.Test.expect(Rail.Linear, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer lin_api_linked"]
      Req.Test.json(conn, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "lin_team_linked"}]}}})
    end)

    {:ok, %LinearWorkspace{id: workspace_id}} =
      Projects.create_linear_workspace(scope, %{
        name: "Linked Workspace",
        external_id: "lin_org_linked",
        token: "lin_api_linked",
        webhook_secret: "whsec_linked"
      })

    attrs = %{
      name: "Linked Project",
      github_repo: "example/linked-#{System.unique_integer([:positive])}",
      github_installation_id: 12_346,
      linear_team_key: "LNK",
      default_branch: "main",
      clone_path: "/tmp/linked"
    }

    assert {:ok,
            %Project{
              linear_team_id: "lin_team_linked",
              linear_workspace: %LinearWorkspace{id: ^workspace_id}
            }} = Projects.create_project(scope, Map.put(attrs, :linear_workspace_id, workspace_id))

    assert {:error, changeset} =
             Projects.create_project(
               scope,
               Map.put(
                 %{attrs | github_repo: "example/unlinked", linear_team_key: "UNL"},
                 :linear_workspace_id,
                 "lw_missing"
               )
             )

    assert %{linear_workspace_id: ["does not exist"]} = errors_on(changeset)
  end

  test "rejects a clone_path that is not a git repository" do
    scope = Scope.for_user(%{admin: true})

    expect(Rail.Git, :git_repo?, fn "/tmp/not-a-checkout" -> false end)

    attrs = %{
      name: "Not A Checkout",
      github_repo: "example/not-a-checkout-#{System.unique_integer([:positive])}",
      github_installation_id: 44_444,
      linear_team_key: "NAC",
      default_branch: "main",
      clone_path: "/tmp/not-a-checkout"
    }

    assert {:error, changeset} = Projects.create_project(scope, attrs)
    assert %{clone_path: ["is not a git repository"]} = errors_on(changeset)
  end

  test "returns error changeset on duplicate github_repo" do
    scope = Scope.for_user(%{admin: true})
    repo = "example/dupe-repo-#{System.unique_integer([:positive])}"

    attrs = %{
      name: "First Project",
      github_repo: repo,
      github_installation_id: 11_111,
      linear_team_key: "FIRST",
      default_branch: "main",
      clone_path: "/tmp/first"
    }

    assert {:ok, %Project{github_repo: ^repo}} = Projects.create_project(scope, attrs)

    assert {:error, changeset} =
             Projects.create_project(scope, %{attrs | name: "Second Project"})

    assert %{github_repo: ["has already been taken"]} = errors_on(changeset)
  end

  test "rejects non-admin user scope" do
    scope = Scope.for_user(%{admin: false})
    repo = "example/unauth-repo-#{System.unique_integer([:positive])}"

    attrs = %{
      name: "Unauthorized Project",
      github_repo: repo,
      github_installation_id: 22_222,
      linear_team_key: "UNAUTH",
      default_branch: "main",
      clone_path: "/tmp/unauth"
    }

    assert {:error, :not_authorized} = Projects.create_project(scope, attrs)
  end

  test "rejects nil scope" do
    repo = "example/nil-repo-#{System.unique_integer([:positive])}"

    attrs = %{
      name: "Nil Scope Project",
      github_repo: repo,
      github_installation_id: 33_333,
      linear_team_key: "NIL",
      default_branch: "main",
      clone_path: "/tmp/nil"
    }

    assert {:error, :not_authorized} = Projects.create_project(nil, attrs)
  end
end
