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
             %{name: "product", model: "claude-opus-5-5", prompt: product},
             %{name: "designer", prompt: designer},
             %{name: "architect", prompt: architect}
           ] = subagents = plan_subagents(task)

    for subagent <- subagents, do: assert(Enum.sort(Map.keys(subagent)) == [:description, :model, :name, :prompt])

    assert product =~ ~r/\AYou are the product agent.\n\n## Working inside Plan/
    assert product =~ "You are performing the Product role inside Rail's Plan step."
    assert designer =~ "You are performing the Designer role inside Rail's Plan step."
    assert architect =~ "You are performing the Architect role inside Rail's Plan step."
    refute Enum.any?([product, designer, architect], &(&1 =~ "is refused"))

    for prompt <- [product, designer, architect] do
      assert prompt =~ "come in Plan's message; call knowledge_search for more."
    end

    assert product =~ "save it with the `save_ticket` tool"
    assert product =~ "update the ticket and save it again"

    assert designer =~ ~r/\AYou are the design agent./
    assert designer =~ "/tmp/rail/scratch/tsk_subagents/design/<key>.html"
    assert designer =~ "update the options it affects"
    assert designer =~ "A comment on the design names its element by a CSS selector. Find the element with that selector"
    assert designer =~ "save under the same key"
    assert designer =~ "Keep the ids and structure of elements nobody commented on"
    assert designer =~ "Put no image in the page as a `data:` URI"

    assert architect =~ ~r/\AYou are the architect agent./
    assert architect =~ "Start as soon as the ticket is saved, while the Designer works"
    assert architect =~ "or leave them until the human picks"
    assert architect =~ "Name the option the plan is written for as `design`"
    assert architect =~ "save the plan again with the change carried everywhere it reaches"
    assert architect =~ "you decide where it splits and save it with `save_split`"
    assert architect =~ "Plan the split on purpose, before you write the parts, as vertical slices"
    assert architect =~ "none is reworked by a later one, and none carries a temporary stand-in"
    assert architect =~ "A child builds on another only where it truly needs that work merged first"
    assert architect =~ "and `builds_screen`, true for each child that builds the approved design's screen"
    assert architect =~ "every save carries every child complete, with its title, ticket and plan"
    assert product =~ "Whether and where the work splits into child tickets is Architect's call"
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
