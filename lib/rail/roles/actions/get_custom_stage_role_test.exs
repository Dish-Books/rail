defmodule Rail.Roles.Actions.GetCustomStageRoleTest do
  use Rail.DataCase, async: true

  alias Rail.Projects.Schemas.Project
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role

  setup do
    project =
      %Project{}
      |> Project.changeset(%{
        name: "Custom Stage Role Project",
        github_repo: "org/custom-stage-role",
        github_installation_id: 4405,
        key: "CSR",
        default_branch: "main",
        clone_path: "/tmp/repos/custom-stage-role"
      })
      |> Repo.insert!()

    {:ok, engineer} =
      Roles.create_role(system_scope(), project, %{
        cli: :claude,
        name: "Engineer",
        stage: :engineer,
        model: "claude-opus-5-5",
        reasoning_effort: :medium,
        system_prompt: "You are an expert engineer."
      })

    %{project: project, engineer: engineer}
  end

  test "the first entry makes the project's role with Engineer's backend and model, and a later one takes Engineer's new model",
       %{project: %{id: project_id} = project, engineer: engineer} do
    assert {:ok,
            %Role{
              id: role_id,
              project_id: ^project_id,
              stage: nil,
              custom_stage: "License check",
              name: "License check",
              cli: :claude,
              model: "claude-opus-5-5",
              reasoning_effort: :medium
            }} = Roles.get_custom_stage_role(project.id, "License check")

    {:ok, _engineer} = Roles.update_role(system_scope(), engineer, %{model: "claude-sonnet-5-5", reasoning_effort: :high})

    assert {:ok, %Role{id: ^role_id, model: "claude-sonnet-5-5", reasoning_effort: :high}} =
             Roles.get_custom_stage_role(project.id, "License check")

    assert {:ok, %Role{id: other_id, custom_stage: "Missing strings"}} =
             Roles.get_custom_stage_role(project.id, "Missing strings")

    assert other_id != role_id
  end
end
