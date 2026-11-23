defmodule Rail.Projects.Actions.CreateProjectTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Projects
  alias Rail.Projects.Schemas.Project
  alias Rail.Scope

  test "creates a project with admin scope" do
    scope = Scope.for_user(%{admin: true})
    repo = "example/repo-#{System.unique_integer([:positive])}"

    attrs = %{
      name: "Rail Admin Project",
      github_repo: repo,
      github_installation_id: 12_345,
      key: "RAIL",
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
      key: "SYS",
      default_branch: "main",
      clone_path: "/tmp/sys"
    }

    assert {:ok, %Project{name: "System Project", github_repo: ^repo}} =
             Projects.create_project(scope, attrs)
  end

  test "a project saves with its key, which is fixed once it has issues" do
    key = "Trk#{System.unique_integer([:positive])}"

    # The default Req adapter raises on any request, so nothing outside Rail is asked about the key.
    assert {:ok, %Project{key: ^key} = project} =
             Projects.create_project(Scope.for_system(), %{
               name: "Rail-tracked",
               github_repo: "example/#{key}",
               github_installation_id: 1,
               key: key,
               default_branch: "main",
               clone_path: "/tmp/#{key}"
             })

    {:ok, _issue} = Issues.create_issue(Scope.for_system(), project, %{title: "First"})

    assert {:error, changeset} = Projects.update_project(Scope.for_system(), project, %{key: "#{key}x"})
    assert %{key: ["cannot change once the project has issues"]} = errors_on(changeset)
  end

  test "returns validation error changeset for missing required fields" do
    scope = Scope.for_user(%{admin: true})

    assert {:error, changeset} = Projects.create_project(scope, %{})

    assert %{
             name: ["can't be blank"],
             github_repo: ["can't be blank"],
             github_installation_id: ["can't be blank"],
             key: ["can't be blank"],
             clone_path: ["can't be blank"]
           } = errors_on(changeset)
  end

  test "rejects a clone_path that is not a git repository" do
    scope = Scope.for_user(%{admin: true})

    expect(Rail.Git, :git_repo?, fn "/tmp/not-a-checkout" -> false end)

    attrs = %{
      name: "Not A Checkout",
      github_repo: "example/not-a-checkout-#{System.unique_integer([:positive])}",
      github_installation_id: 44_444,
      key: "NAC",
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
      key: "FIRST",
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
      key: "UNAUTH",
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
      key: "NIL",
      default_branch: "main",
      clone_path: "/tmp/nil"
    }

    assert {:error, :not_authorized} = Projects.create_project(nil, attrs)
  end
end
