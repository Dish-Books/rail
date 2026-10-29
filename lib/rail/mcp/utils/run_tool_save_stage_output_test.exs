defmodule Rail.Mcp.Utils.RunToolSaveStageOutputTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Schemas.IssueStage
  alias Rail.Mcp
  alias Rail.Mcp.RunContext
  alias Rail.Pipeline
  alias Rail.Roles
  alias Rail.Tools.Schemas.OsProcess

  setup %{project: project} do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_rtsso_1", "identifier" => "RTSSO-1", "title" => "Dependency updates"}
          }
        }
      })
    end)

    stages = [
      %IssueStage{stage: :plan},
      %IssueStage{stage: :engineer},
      %IssueStage{stage: :custom, name: "License check", prompt: "Check each license."},
      %IssueStage{stage: :review}
    ]

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{title: "Dependency updates", stages: stages})
    {:ok, task} = Pipeline.create_task(issue, {:custom, "License check"})
    on_exit(fn -> File.rm_rf(task.scratch_path) end)
    {:ok, role} = Roles.get_custom_stage_role(project.id, "License check")

    %{task: task, context: %RunContext{role: role, os_process: %OsProcess{task_id: task.id}}}
  end

  test "the tool saves the output and tells the agent to end its turn", %{task: task, context: context} do
    assert {:ok, %{"content" => [%{"text" => "Saved. Saving again replaces it. End your turn now" <> _rest}]}} =
             Mcp.call_run_tool(context, "save_stage_output", %{"markdown" => "## License check\n\nAll MIT."})

    assert [%{markdown: "## License check\n\nAll MIT."}] = Pipeline.read_stage_outputs(task)
  end

  test "an empty or missing output is refused", %{task: task, context: context} do
    assert {:error, {:refused, "Nothing saved: `markdown` is empty." <> _rest}} =
             Mcp.call_run_tool(context, "save_stage_output", %{"markdown" => " "})

    assert {:error, {:refused, _empty}} = Mcp.call_run_tool(context, "save_stage_output", %{})
    assert [] = Pipeline.read_stage_outputs(task)
  end

  test "a save once the stage was approved is refused", %{task: task, context: context} do
    {:ok, _reviewing} = Pipeline.update_task(task, %{stage: :review})

    assert {:error, {:refused, "Nothing saved: this stage was approved" <> _rest}} =
             Mcp.call_run_tool(context, "save_stage_output", %{"markdown" => "Late."})
  end
end
