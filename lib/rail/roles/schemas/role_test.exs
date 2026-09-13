defmodule Rail.Roles.Schemas.RoleTest do
  use Rail.DataCase, async: true

  alias Rail.Projects
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role

  setup do
    {:ok, backend} =
      Rail.Tools.create_backend(system_scope(), %{name: :claude, executable_path: "/usr/bin/true"})

    scope = system_scope()

    {:ok, project} =
      Projects.create_project(scope, %{
        name: "Role Schema Project",
        github_repo: "org/role-schema",
        github_installation_id: 4503,
        linear_team_id: "team_role_schema",
        linear_team_key: "RLS",
        default_branch: "main",
        clone_path: "/tmp/repos/role-schema"
      })

    {:ok, role} =
      Roles.create_role(scope, project, %{
        backend_id: backend.id,
        name: "Engineer",
        stage: :engineer,
        model: "claude-3-7-sonnet",
        system_prompt: "You are an expert engineer."
      })

    %{backend: backend, project: project, role: role}
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

  test "changeset validates required fields" do
    changeset = Role.changeset(%Role{}, %{})

    assert %{
             project_id: ["can't be blank"],
             name: ["can't be blank"],
             model: ["can't be blank"],
             system_prompt: ["can't be blank"],
             backend_id: ["can't be blank"]
           } = errors_on(changeset)
  end

  test "changeset accepts valid attributes and sets defaults", %{backend: backend, project: project} do
    attrs = %{
      name: "Architect Agent",
      model: "claude-3-7-sonnet",
      system_prompt: "You design systems.",
      backend_id: backend.id
    }

    changeset = Role.changeset(%Role{}, attrs, project.id)

    assert changeset.valid?
    assert get_field(changeset, :max_concurrent) == 1
    assert get_field(changeset, :position) == 0
  end

  test "changeset requires a backend", %{project: project} do
    attrs = %{
      name: "Architect Agent",
      model: "claude-3-7-sonnet",
      system_prompt: "You design systems."
    }

    changeset = Role.changeset(%Role{}, attrs, project.id)

    refute changeset.valid?
    assert %{backend_id: ["can't be blank"]} = errors_on(changeset)
  end

  test "changeset validates numeric bounds", %{project: project} do
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

  test "changeset validates enum types", %{project: project} do
    attrs = %{
      name: "Invalid Enums",
      model: "model-1",
      system_prompt: "Prompt",
      stage: "invalid_stage",
      reasoning_effort: "invalid_effort"
    }

    changeset = Role.changeset(%Role{}, attrs, project.id)

    assert %{
             stage: ["is invalid"],
             reasoning_effort: ["is invalid"]
           } = errors_on(changeset)
  end

  test "changeset enforces partial unique index on project_id and stage", %{backend: backend, project: project} do
    assert {:error, changeset} =
             %Role{}
             |> Role.changeset(
               %{
                 name: "Engineer 2",
                 stage: :engineer,
                 model: "claude-3-7-sonnet",
                 system_prompt: "Code 2",
                 backend_id: backend.id
               },
               project.id
             )
             |> Repo.insert()

    assert %{stage: ["has already been taken"]} = errors_on(changeset)
  end

  test "allows multiple unbound roles with stage: nil in the same project", %{backend: backend, project: project} do
    assert {:ok, %Role{stage: nil, name: "Unbound 1"}} =
             %Role{}
             |> Role.changeset(
               %{name: "Unbound 1", stage: nil, model: "m", system_prompt: "p", backend_id: backend.id},
               project.id
             )
             |> Repo.insert()

    assert {:ok, %Role{stage: nil, name: "Unbound 2"}} =
             %Role{}
             |> Role.changeset(
               %{name: "Unbound 2", stage: nil, model: "m", system_prompt: "p", backend_id: backend.id},
               project.id
             )
             |> Repo.insert()
  end

  test "ignores project_id passed in attrs to prevent unverified overrides", %{project: project} do
    other_project_id = "prj_000000000000000000000000"

    attrs = %{
      name: "Role Safe",
      model: "claude",
      system_prompt: "Prompt",
      project_id: other_project_id
    }

    changeset = Role.changeset(%Role{}, attrs, project.id)
    assert get_field(changeset, :project_id) == project.id
  end

  test "validates foreign key on project_id", %{backend: backend} do
    attrs = %{
      name: "Missing Project Role",
      model: "claude",
      system_prompt: "Prompt",
      backend_id: backend.id
    }

    assert {:error, changeset} =
             %Role{}
             |> Role.changeset(attrs, "prj_000000000000000000000000")
             |> Repo.insert()

    assert %{project_id: ["does not exist"]} = errors_on(changeset)
  end

  test "preloads belongs_to project", %{role: %Role{project_id: project_id} = role} do
    preloaded = Repo.preload(role, :project)
    assert %Project{id: ^project_id} = preloaded.project
  end
end
