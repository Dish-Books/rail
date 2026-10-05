defmodule Rail.Pipeline.Utils.PlanSubagentsTest do
  use Rail.DataCase, async: true

  import Rail.Pipeline.Utils.PlanSubagents

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Roles

  setup %{project: project} do
    %{task: %Task{project_id: project.id, scratch_path: "/tmp/rail/scratch/tsk_subagents"}}
  end

  test "each subagent is its role's prompt and model followed by the rules for its output, with no tool list", %{
    task: task
  } do
    assert [
             %{name: "product", stage: :product, role_name: "product role", model: "claude-opus-5-5", prompt: product},
             %{name: "designer", stage: :design, role_name: "design role", prompt: designer},
             %{name: "architect", stage: :architect, role_name: "architect role", prompt: architect}
           ] = subagents = plan_subagents(task)

    refute Enum.any?(subagents, &Map.has_key?(&1, :tools))

    assert product =~ ~r/\AYou are the product agent.\n\n## Working inside Plan/
    assert product =~ "save it with the `save_ticket` tool"
    assert product =~ "update the ticket and save it again"

    assert designer =~ ~r/\AYou are the design agent./
    assert designer =~ "/tmp/rail/scratch/tsk_subagents/design/<key>.html"
    assert designer =~ "update the options it affects"

    assert architect =~ ~r/\AYou are the architect agent./
    assert architect =~ "Leave the screen-specific details until the human picks"
    assert architect =~ "Name the option the plan is written for as `design`"
    assert architect =~ "save the plan again with the change carried everywhere it reaches"
  end

  test "a role's description describes its subagent, and its name stands in when it has none", %{
    project: project,
    task: task
  } do
    {:ok, role} = Roles.get_role(project_id: project.id, stage: :product)
    {:ok, _role} = Roles.update_role(system_scope(), role, %{description: "Writes the ticket"})

    assert [%{description: "Writes the ticket"}, %{description: "design role"}, _architect] = plan_subagents(task)
  end

  test "a role the project does not have is no subagent", %{task: task} do
    stub(Roles, :get_role, fn
      [project_id: _id, stage: :design] -> {:error, :role_not_found}
      by -> call_original(Roles, :get_role, [by])
    end)

    assert [%{name: "product"}, %{name: "architect"}] = plan_subagents(task)
  end
end
