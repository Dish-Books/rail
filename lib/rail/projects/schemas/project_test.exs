defmodule Rail.Projects.Schemas.ProjectTest do
  use Rail.DataCase, async: true

  alias Rail.Projects.Schemas.Project
  alias Rail.Repo

  test "changeset validates required fields" do
    changeset = Project.changeset(%Project{}, %{})

    assert %{
             name: ["can't be blank"],
             github_repo: ["can't be blank"],
             github_installation_id: ["can't be blank"],
             default_branch: ["can't be blank"],
             key: ["can't be blank"],
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
      key: "RAIL",
      clone_path: "/tmp/rail"
    }

    changeset = Project.changeset(%Project{}, attrs)
    assert changeset.valid?
    assert get_field(changeset, :default_branch) == "main"
    assert get_field(changeset, :active) == true
    assert get_field(changeset, :ci_reserved_cpus) == 1
  end

  test "CI reserves at least one CPU" do
    changeset = Project.changeset(%Project{}, %{ci_reserved_cpus: 0})

    assert %{ci_reserved_cpus: ["must be at least 1 CPU"]} = errors_on(changeset)
  end

  test "a key is short and made of letters, digits, - and _" do
    changeset = Project.changeset(%Project{}, %{key: "foo#1"})
    assert %{key: ["use letters, digits, - and _"]} = errors_on(changeset)

    changeset = Project.changeset(%Project{}, %{key: String.duplicate("k", 21)})
    assert %{key: ["should be at most 20 character(s)"]} = errors_on(changeset)
  end

  test "the database refuses a project with no key" do
    assert_raise Postgrex.Error, ~r/null value in column "key"/, fn ->
      Repo.insert!(%Project{
        name: "No Team",
        github_repo: "example/no-team-#{System.unique_integer([:positive])}",
        github_installation_id: 1,
        default_branch: "main",
        clone_path: "/tmp/no-team"
      })
    end
  end

  test "changeset enforces uniqueness on github_repo" do
    repo = "example/repo-#{System.unique_integer([:positive])}"

    base_attrs = %{
      name: "Project 1",
      github_repo: repo,
      github_installation_id: 99_001,
      default_branch: "main",
      key: "P1",
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
end
