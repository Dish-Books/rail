defmodule Rail.Roles.Schemas.RoleTest do
  use Rail.DataCase, async: true

  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Roles.Schemas.Role

  test "factory builds a valid role struct" do
    role = Role.factory()

    assert %Role{
             project_id: "prj_" <> _id,
             stage: :engineer,
             name: "Engineer " <> _name,
             cli_backend: :claude,
             model: "claude-3-7-sonnet",
             reasoning_effort: :high,
             system_prompt: "You are an expert engineer.",
             max_concurrent: 1,
             position: 0
           } = role
  end

  test "canonical_stages/0 returns list of 9 stages" do
    stages = Role.canonical_stages()
    assert length(stages) == 9
    assert :debugger in stages
    assert :design in stages
    refute :designer in stages
    # Rebase is an engineer action, not a stage a role can bind to
    refute :rebase in stages
  end

  test "stages/0, backends/0, and reasoning_efforts/0 return allowed values" do
    stages = Role.stages()
    assert :product in stages
    assert :merged in stages
    assert :debugger in stages

    assert Role.backends() == [:claude, :agy, :codex]
    assert Role.reasoning_efforts() == [:low, :medium, :high]
  end

  test "changeset validates required fields" do
    changeset = Role.changeset(%Role{}, %{})

    assert %{
             project_id: ["can't be blank"],
             name: ["can't be blank"],
             model: ["can't be blank"],
             system_prompt: ["can't be blank"]
           } = errors_on(changeset)
  end

  test "changeset accepts valid attributes and sets defaults" do
    project = create_test_project()

    attrs = %{
      name: "Architect Agent",
      model: "claude-3-7-sonnet",
      system_prompt: "You design systems."
    }

    changeset = Role.changeset(%Role{}, attrs, project.id)

    assert changeset.valid?
    assert get_field(changeset, :cli_backend) == :claude
    assert get_field(changeset, :max_concurrent) == 1
    assert get_field(changeset, :position) == 0
  end

  test "changeset validates numeric bounds" do
    project = create_test_project()

    attrs = %{
      name: "Role with Invalid Bounds",
      model: "claude-3-7-sonnet",
      system_prompt: "System prompt",
      max_concurrent: 0,
      position: -1
    }

    changeset = Role.changeset(%Role{}, attrs, project.id)

    assert %{
             max_concurrent: ["must be greater than or equal to 1"],
             position: ["must be greater than or equal to 0"]
           } = errors_on(changeset)
  end

  test "changeset validates enum types" do
    project = create_test_project()

    attrs = %{
      name: "Invalid Enums",
      model: "model-1",
      system_prompt: "Prompt",
      stage: "invalid_stage",
      cli_backend: "invalid_backend",
      reasoning_effort: "invalid_effort"
    }

    changeset = Role.changeset(%Role{}, attrs, project.id)

    assert %{
             stage: ["is invalid"],
             cli_backend: ["is invalid"],
             reasoning_effort: ["is invalid"]
           } = errors_on(changeset)
  end

  test "changeset enforces partial unique index on project_id and stage" do
    project = create_test_project()

    assert {:ok, %Role{stage: :engineer}} =
             %Role{}
             |> Role.changeset(
               %{
                 name: "Engineer 1",
                 stage: :engineer,
                 model: "claude-3-7-sonnet",
                 system_prompt: "Code"
               },
               project.id
             )
             |> Repo.insert()

    assert {:error, changeset} =
             %Role{}
             |> Role.changeset(
               %{
                 name: "Engineer 2",
                 stage: :engineer,
                 model: "claude-3-7-sonnet",
                 system_prompt: "Code 2"
               },
               project.id
             )
             |> Repo.insert()

    assert %{stage: ["has already been taken"]} = errors_on(changeset)
  end

  test "allows multiple unbound roles with stage: nil in the same project" do
    project = create_test_project()

    assert {:ok, %Role{stage: nil, name: "Unbound 1"}} =
             %Role{}
             |> Role.changeset(
               %{name: "Unbound 1", stage: nil, model: "m", system_prompt: "p"},
               project.id
             )
             |> Repo.insert()

    assert {:ok, %Role{stage: nil, name: "Unbound 2"}} =
             %Role{}
             |> Role.changeset(
               %{name: "Unbound 2", stage: nil, model: "m", system_prompt: "p"},
               project.id
             )
             |> Repo.insert()
  end

  test "ignores project_id passed in attrs to prevent unverified overrides" do
    project1 = create_test_project()
    other_project_id = "prj_000000000000000000000000"

    attrs = %{
      name: "Role Safe",
      model: "claude",
      system_prompt: "Prompt",
      project_id: other_project_id
    }

    changeset = Role.changeset(%Role{}, attrs, project1.id)
    assert get_field(changeset, :project_id) == project1.id
  end

  test "validates foreign key on project_id" do
    attrs = %{
      name: "Missing Project Role",
      model: "claude",
      system_prompt: "Prompt"
    }

    assert {:error, changeset} =
             %Role{}
             |> Role.changeset(attrs, "prj_000000000000000000000000")
             |> Repo.insert()

    assert %{project_id: ["does not exist"]} = errors_on(changeset)
  end

  test "preloads belongs_to project" do
    %Role{project_id: project_id} = role = create_test_role()
    preloaded = Repo.preload(role, :project)
    assert %Project{id: ^project_id} = preloaded.project
  end
end
