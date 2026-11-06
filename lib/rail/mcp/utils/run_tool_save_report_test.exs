defmodule Rail.Mcp.Utils.RunToolSaveReportTest do
  use Rail.DataCase, async: true

  import Rail.Mcp.Utils.RunToolSaveReport

  alias Rail.Mcp
  alias Rail.Mcp.RunContext
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Roles
  alias Rail.Tools.Schemas.OsProcess

  setup do
    # A role's prompt is read from the project's clone, which another test may have made, so reading it here
    # would spawn git: these see no prompt file on the default branch, as when there is no clone.
    stub(Rail.Git, :read_default_branch_file, fn _project, path -> {:error, "fatal: path '#{path}' does not exist"} end)

    scratch = Path.join(System.tmp_dir!(), "run_tool_save_report_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(scratch) end)

    %{task: %Task{id: "tsk_run_tool_save_report", scratch_path: scratch}}
  end

  # The report is the caller's own, so the role it is saved under is the run's, never an argument.
  test "saves the report as the calling run's role", %{task: task} do
    assert {:ok, "Report saved." <> _rest} = run_tool_save_report(task, %{"report" => "Two rows."}, stage: :qa)
    assert [qa: "Two rows."] = Pipeline.read_reports(task)
  end

  test "an empty or missing report is refused", %{task: task} do
    assert {:refused, "Nothing saved: `report` is empty." <> _rest} =
             run_tool_save_report(task, %{"report" => " "}, stage: :engineer)

    assert {:refused, _empty} = run_tool_save_report(task, %{}, stage: :engineer)
    assert [] = Pipeline.read_reports(task)
  end

  test "is a tool of the code reviewer's, saved under its role", %{project: project} do
    task = learnings_task(project, "RTSR-1", :review)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)
    {:ok, role} = Roles.get_role(project_id: project.id, stage: :review)
    context = %RunContext{role: role, os_process: %OsProcess{task_id: task.id}}

    assert {:ok, %{"content" => [%{"text" => "Report saved." <> _rest}]}} =
             Mcp.call_run_tool(context, "save_report", %{"report" => "Nothing to report."})

    assert [review: "Nothing to report."] = Pipeline.read_reports(task)
  end
end
