defmodule Rail.Pipeline.Actions.ReadPlanTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline

  setup %{project: project} do
    scope = system_scope()

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_read_plan_1", "identifier" => "RDP-1", "title" => "Read Plan"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "Read Plan"})
    {:ok, task} = Pipeline.create_task(issue, :architect)
    plans_dir = Path.join(task.scratch_path, "plans")
    File.mkdir_p!(plans_dir)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    %{task: Repo.preload(task, :issue), plan_path: Path.join(plans_dir, "RDP-1.md")}
  end

  test "reads the plan the architect wrote", %{task: task, plan_path: path} do
    File.write!(path, "## Implementation plan\n\n### Approach\nExtend the existing module.\n")

    assert Pipeline.read_plan(task) =~ "Extend the existing module."
  end

  test "an unwritten plan is no plan", %{task: task} do
    assert Pipeline.read_plan(task) == nil
  end

  test "a blank file is no plan: the agent opened it but did not write it", %{task: task, plan_path: path} do
    File.write!(path, "   \n\n")

    assert Pipeline.read_plan(task) == nil
  end
end
