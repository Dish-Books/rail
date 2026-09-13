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
             linear_team_id: ["can't be blank"],
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
      linear_team_id: "team_abc",
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
      linear_team_id: "team_1",
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
               linear_team_id: "team_ws",
               linear_team_key: "PWS",
               clone_path: "/tmp/pws"
             })
             |> Repo.insert()

    assert %LinearWorkspace{id: ^workspace_id, project_id: ^project_id} =
             Repo.get_by(LinearWorkspace, project_id: project_id)
  end
end
