defmodule Rail.Pipeline.Utils.ArchitectRunFinishedTest do
  use Rail.DataCase, async: true

  import Rail.Pipeline.Utils.ArchitectRunFinished

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Roles

  setup %{project: project} do
    scope = system_scope()

    {:ok, role} = Roles.get_role(project_id: project.id, stage: :architect)

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_afn_1", "identifier" => "AFN-1", "title" => "Architect Finished"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "Architect Finished"})
    {:ok, task} = Pipeline.create_task(issue, :architect)
    plans_dir = Path.join(task.scratch_path, "plans")
    File.mkdir_p!(plans_dir)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :running,
        conversation_id: "sess_architect_finished",
        started_at: DateTime.utc_now()
      })

    %{task: task, run: Repo.preload(run, [:task, :role]), plan_path: Path.join(plans_dir, "AFN-1.md")}
  end

  test "a run that wrote its plan is left clean for a human to approve", %{
    task: task,
    run: run,
    plan_path: path
  } do
    File.write!(path, "## Implementation plan\n\n### Approach\nExtend the existing module.\n")

    assert %Run{error: nil} = architect_run_finished(run, [])
    assert %Task{stage: :architect} = Repo.reload!(task)
  end

  test "a run that exited without a plan records that rather than parking a human in front of nothing", %{
    task: task,
    run: run
  } do
    assert %Run{error: "The architect did not write plans/AFN-1.md."} = architect_run_finished(run, [])
    assert %Task{stage: :architect} = Repo.reload!(task)
  end

  test "a plan that is only whitespace is no plan", %{run: run, plan_path: path} do
    File.write!(path, "\n  \n")

    assert %Run{error: "The architect did not write plans/AFN-1.md."} = architect_run_finished(run, [])
  end
end
