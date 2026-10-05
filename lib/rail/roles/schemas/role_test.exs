defmodule Rail.Roles.Schemas.RoleTest do
  use Rail.DataCase, async: true

  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role

  setup do
    project =
      %Project{}
      |> Project.changeset(%{
        name: "Role Schema Project",
        github_repo: "org/role-schema",
        github_installation_id: 4401,
        linear_team_key: "RSC",
        default_branch: "main",
        clone_path: "/tmp/repos/role-schema"
      })
      |> Repo.insert!()

    scope = system_scope()

    {:ok, role} =
      Roles.create_role(scope, project, %{
        cli: :claude,
        name: "Engineer",
        stage: :engineer,
        model: "claude-opus-5-5",
        system_prompt: "You are an expert engineer."
      })

    %{project: project, role: role}
  end

  test "canonical_stages/0 returns list of 11 stages" do
    stages = Role.canonical_stages()
    assert length(stages) == 11
    assert :plan in stages
    assert :triage in stages
    assert :curator in stages
    assert :debugger in stages
    assert :design in stages
    refute :designer in stages
    # Rebase is an engineer action, not a stage a role can bind to
    refute :rebase in stages
  end

  test "a role can be saved at the curator stage, which no task enters", %{project: project} do
    assert {:ok, %Role{stage: :curator}} =
             Roles.create_role(system_scope(), project, %{
               cli: :claude,
               name: "Curator",
               stage: :curator,
               model: "claude-opus-5-5",
               system_prompt: "You curate."
             })
  end

  test "changeset validates required fields" do
    changeset = Role.changeset(%Role{}, %{})

    assert %{
             project_id: ["can't be blank"],
             name: ["can't be blank"],
             model: ["can't be blank"],
             system_prompt: ["can't be blank"],
             cli: ["can't be blank"]
           } = errors_on(changeset)
  end

  test "changeset accepts valid attributes and sets defaults", %{project: project} do
    attrs = %{
      name: "Architect Agent",
      model: "claude-opus-5-5",
      system_prompt: "You design systems.",
      cli: :claude
    }

    changeset = Role.changeset(%Role{}, Map.put(attrs, :project_id, project.id))

    assert changeset.valid?
    assert get_field(changeset, :max_concurrent) == 1
    assert get_field(changeset, :position) == 0
  end

  test "changeset requires a backend", %{project: project} do
    attrs = %{
      name: "Architect Agent",
      model: "claude-opus-5-5",
      system_prompt: "You design systems."
    }

    changeset = Role.changeset(%Role{}, Map.put(attrs, :project_id, project.id))

    refute changeset.valid?
    assert %{cli: ["can't be blank"]} = errors_on(changeset)
  end

  test "changeset validates numeric bounds", %{project: project} do
    attrs = %{
      name: "Role with Invalid Bounds",
      model: "claude-opus-5-5",
      system_prompt: "System prompt",
      max_concurrent: 0,
      position: -1
    }

    changeset = Role.changeset(%Role{}, Map.put(attrs, :project_id, project.id))

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

    changeset = Role.changeset(%Role{}, Map.put(attrs, :project_id, project.id))

    assert %{
             stage: ["is invalid"],
             reasoning_effort: ["is invalid"]
           } = errors_on(changeset)
  end

  test "changeset enforces partial unique index on project_id and stage", %{project: project} do
    assert {:error, changeset} =
             %Role{}
             |> Role.changeset(%{
               project_id: project.id,
               name: "Engineer 2",
               stage: :engineer,
               model: "claude-opus-5-5",
               system_prompt: "Code 2",
               cli: :claude
             })
             |> Repo.insert()

    assert %{stage: ["has already been taken"]} = errors_on(changeset)
  end

  test "allows multiple unbound roles with stage: nil in the same project", %{project: project} do
    assert {:ok, %Role{stage: nil, name: "Unbound 1"}} =
             %Role{}
             |> Role.changeset(%{
               project_id: project.id,
               name: "Unbound 1",
               stage: nil,
               model: "m",
               system_prompt: "p",
               cli: :claude
             })
             |> Repo.insert()

    assert {:ok, %Role{stage: nil, name: "Unbound 2"}} =
             %Role{}
             |> Role.changeset(%{
               project_id: project.id,
               name: "Unbound 2",
               stage: nil,
               model: "m",
               system_prompt: "p",
               cli: :claude
             })
             |> Repo.insert()
  end

  test "validates foreign key on project_id" do
    attrs = %{
      name: "Missing Project Role",
      model: "claude",
      system_prompt: "Prompt",
      cli: :claude
    }

    assert {:error, changeset} =
             %Role{}
             |> Role.changeset(Map.put(attrs, :project_id, "prj_000000000000000000000000"))
             |> Repo.insert()

    assert %{project_id: ["does not exist"]} = errors_on(changeset)
  end

  test "preloads belongs_to project", %{role: %Role{project_id: project_id} = role} do
    preloaded = Repo.preload(role, :project)
    assert %Project{id: ^project_id} = preloaded.project
  end

  test "fit_count/2 says how many fit at once and which resource runs out first" do
    capacity = %{cpus: 14, memory_gb: 56}

    assert %{count: 7, limited_by: :cpus} = Role.fit_count(%Role{reserved_cpus: 2, reserved_memory_gb: 4}, capacity)
    assert %{count: 3, limited_by: :memory} = Role.fit_count(%{reserved_cpus: 1, reserved_memory_gb: 16}, capacity)
    assert %{count: 0, limited_by: :cpus} = Role.fit_count(%{reserved_cpus: 16, reserved_memory_gb: 4}, capacity)
  end

  test "a reservation of nothing is refused" do
    changeset = Role.changeset(%Role{}, %{reserved_cpus: 0, reserved_memory_gb: 0})

    assert %{reserved_cpus: ["must be greater than or equal to 1"], reserved_memory_gb: [_message]} =
             errors_on(changeset)
  end
end
