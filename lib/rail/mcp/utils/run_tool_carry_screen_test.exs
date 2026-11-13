defmodule Rail.Mcp.Utils.RunToolCarryScreenTest do
  use Rail.DataCase, async: true

  alias Rail.Mcp
  alias Rail.Mcp.RunContext
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Round
  alias Rail.Roles
  alias Rail.Tools.Schemas.OsProcess

  setup %{project: project} do
    task = learnings_task(project, "RCS-1", :review)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)
    folder = Path.join([task.scratch_path, "qa", "screens", "file-list"])
    File.mkdir_p!(folder)
    File.write!(Path.join(folder, "1.jpg"), "jpeg")
    shot = %{label: "File list", commit: String.duplicate("c", 40), taken_at: "2026-10-08T09:00:00Z", round: 1}
    File.write!(Path.join(folder, "1.json"), Jason.encode!(shot))
    Repo.insert!(%Round{task_id: task.id, number: 2})
    {:ok, qa} = Roles.get_role(project_id: project.id, stage: :qa)

    %{task: task, context: %RunContext{role: qa, os_process: %OsProcess{task_id: task.id}}}
  end

  test "carries an earlier round's state into this one and says which commit its picture is of", %{
    task: task,
    context: context
  } do
    said = "Carried file-list into this round as it is: screens/file-list/1.jpg, the picture on ccccccc."

    assert {:ok, %{"content" => [%{"type" => "text", "text" => ^said}]}} =
             Mcp.call_run_tool(context, "carry_screen", %{"key" => "file-list"})

    assert [%{key: "file-list", round: 2}] = Pipeline.list_screens(task)
  end

  test "refuses a state already this round's, one no round shot, and a call without a key", %{context: context} do
    {:ok, _carried} = Mcp.call_run_tool(context, "carry_screen", %{"key" => "file-list"})

    assert {:error, {:refused, "Refused, nothing changed. file-list is already this round's" <> _rest}} =
             Mcp.call_run_tool(context, "carry_screen", %{"key" => "file-list"})

    assert {:error, {:refused, "Refused, nothing carried. No earlier round has a state `toolbar`." <> _rest}} =
             Mcp.call_run_tool(context, "carry_screen", %{"key" => "toolbar"})

    assert {:error, {:refused, "Refused, nothing carried. carry_screen needs the `key`" <> _rest}} =
             Mcp.call_run_tool(context, "carry_screen", %{})
  end
end
