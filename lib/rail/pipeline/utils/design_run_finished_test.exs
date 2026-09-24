defmodule Rail.Pipeline.Utils.DesignRunFinishedTest do
  use Rail.DataCase, async: true

  import Rail.Pipeline.Utils.DesignRunFinished

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Roles

  setup %{project: project} do
    scope = system_scope()

    {:ok, role} = Roles.get_role(project_id: project.id, stage: :design)

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_design_finished_1", "identifier" => "DFN-1", "title" => "Design Finished"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "Design Finished"})
    {:ok, task} = Pipeline.create_task(issue, :design)
    design_dir = Path.join(task.scratch_path, "design")
    File.mkdir_p!(design_dir)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :finished,
        error: "An earlier turn left this.",
        started_at: DateTime.utc_now()
      })

    %{run: Repo.preload(run, [:task, :role]), design_dir: design_dir}
  end

  test "a run that wrote no manifest records that it did not", %{run: run} do
    assert %Run{error: "The designer did not write design/manifest.json."} = design_run_finished(run, [])
  end

  test "a run that wrote other than three options records how many", %{run: run, design_dir: dir} do
    File.write!(
      Path.join(dir, "manifest.json"),
      ~s({"options": [{"key": "a", "title": "A"}, {"key": "b", "title": "B"}]})
    )

    assert %Run{error: "The designer wrote 2 design options, not 3."} = design_run_finished(run, [])
  end

  test "names the options still missing a page or a screenshot", %{run: run, design_dir: dir} do
    File.write!(
      Path.join(dir, "manifest.json"),
      ~s({"options": [{"key": "a", "title": "A"}, {"key": "b", "title": "B"}, {"key": "c", "title": "C"}]})
    )

    for key <- ["a", "b", "c"], do: File.write!(Path.join(dir, "#{key}.html"), "<p>#{key}</p>")
    File.write!(Path.join(dir, "a.png"), "png")

    assert %Run{error: "Design options missing a page or screenshot: b, c."} = design_run_finished(run, [])
  end

  test "three complete options clear the error and leave the task where it is", %{run: run, design_dir: dir} do
    File.write!(
      Path.join(dir, "manifest.json"),
      ~s({"options": [{"key": "a", "title": "A"}, {"key": "b", "title": "B"}, {"key": "c", "title": "C"}]})
    )

    for key <- ["a", "b", "c"] do
      File.write!(Path.join(dir, "#{key}.html"), "<p>#{key}</p>")
      File.write!(Path.join(dir, "#{key}.png"), "png")
    end

    assert %Run{error: nil, task: %Task{}} = design_run_finished(run, [])
    assert %Run{error: nil} = Repo.reload!(run)
    assert %Task{stage: :design} = Repo.get!(Task, run.task_id)
  end
end
