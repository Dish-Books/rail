defmodule Rail.Pipeline.Utils.ReviewSubagentsTest do
  use Rail.DataCase, async: true

  import Rail.Pipeline.Utils.ReviewSubagents

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Roles

  setup %{project: project} do
    %{task: %Task{project_id: project.id, scratch_path: "/tmp/rail/scratch/tsk_review_subagents"}}
  end

  test "each subagent is its role's prompt and model followed by Rail's rules for working inside Review", %{
    task: task
  } do
    assert [
             %{name: "code-reviewer", model: "claude-opus-5-5", prompt: reviewer, description: "review role"},
             %{name: "explorer", prompt: explorer, description: "qa role"},
             %{name: "engineer", prompt: engineer, description: "engineer role"},
             %{name: "demo-recorder", prompt: recorder, description: "demo role"}
           ] = subagents = review_subagents(task)

    for subagent <- subagents, do: assert(Enum.sort(Map.keys(subagent)) == [:description, :model, :name, :prompt])

    assert reviewer =~ ~r/\AYou are the review agent.\n\n## Working inside Review/
    assert explorer =~ ~r/\AYou are the qa agent.\n\n## Working inside Review/
    assert engineer =~ ~r/\AYou are the engineer agent.\n\n## Working inside Review/
    assert recorder =~ ~r/\AYou are the demo agent.\n\n## Working inside Review/
    assert explorer =~ "/tmp/rail/scratch/tsk_review_subagents"
  end

  test "changing one role's model changes that subagent's and no other", %{project: project, task: task} do
    {:ok, qa} = Roles.get_role(project_id: project.id, stage: :qa)
    {:ok, _qa} = Roles.update_role(system_scope(), qa, %{model: "claude-sonnet-5-5"})

    assert [
             %{name: "code-reviewer", model: "claude-opus-5-5"},
             %{name: "explorer", model: "claude-sonnet-5-5"},
             %{name: "engineer", model: "claude-opus-5-5"},
             %{name: "demo-recorder", model: "claude-opus-5-5"}
           ] = review_subagents(task)
  end

  test "a role the project does not have is no subagent", %{task: task} do
    stub(Roles, :get_role, fn
      [project_id: _id, stage: :demo] -> {:error, :role_not_found}
      by -> call_original(Roles, :get_role, [by])
    end)

    assert ["code-reviewer", "explorer", "engineer"] = task |> review_subagents() |> Enum.map(& &1.name)
  end
end
