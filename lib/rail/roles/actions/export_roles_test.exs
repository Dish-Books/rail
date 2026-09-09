defmodule Rail.Roles.Actions.ExportRolesTest do
  use Rail.DataCase, async: true

  alias Rail.Roles
  alias Rail.Scope

  test "exports project roles omitting internal IDs" do
    scope = Scope.for_user(%{admin: true})
    project = create_test_project()

    create_test_role(
      project_id: project.id,
      stage: :engineer,
      name: "Senior Engineer",
      description: "Writes clean code",
      icon_name: "hero-code",
      cli_backend: :claude,
      model: "claude-3-7-sonnet",
      reasoning_effort: :high,
      system_prompt: "Write tests first.",
      max_concurrent: 2,
      position: 1
    )

    create_test_role(
      project_id: project.id,
      stage: nil,
      name: "Ad-hoc Reviewer",
      description: nil,
      icon_name: nil,
      cli_backend: :agy,
      model: "gpt-4o",
      reasoning_effort: nil,
      system_prompt: "Review PRs.",
      max_concurrent: 1,
      position: 2
    )

    assert {:ok, exported} = Roles.export_roles(scope, project.id)

    assert [
             %{
               "stage" => "engineer",
               "name" => "Senior Engineer",
               "description" => "Writes clean code",
               "icon_name" => "hero-code",
               "cli_backend" => "claude",
               "model" => "claude-3-7-sonnet",
               "reasoning_effort" => "high",
               "system_prompt" => "Write tests first.",
               "max_concurrent" => 2,
               "position" => 1
             },
             %{
               "stage" => nil,
               "name" => "Ad-hoc Reviewer",
               "description" => nil,
               "icon_name" => nil,
               "cli_backend" => "agy",
               "model" => "gpt-4o",
               "reasoning_effort" => nil,
               "system_prompt" => "Review PRs.",
               "max_concurrent" => 1,
               "position" => 2
             }
           ] = exported

    assert {:ok, json_string} = Jason.encode(exported)
    assert byte_size(json_string) > 0
    assert json_string =~ "Senior Engineer"
  end

  test "returns empty list for project with no roles" do
    scope = Scope.for_user(%{admin: false})
    project = create_test_project()

    assert {:ok, []} = Roles.export_roles(scope, project.id)
  end

  test "returns not authorized for nil or invalid scope" do
    project = create_test_project()
    assert {:error, :not_authorized} = Roles.export_roles(nil, project.id)
    assert {:error, :not_authorized} = Roles.export_roles(%Scope{user: nil, system: false}, project.id)
    assert {:error, :not_authorized} = Roles.export_roles(Scope.for_system(), nil)
  end
end
