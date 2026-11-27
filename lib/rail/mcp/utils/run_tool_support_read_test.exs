defmodule Rail.Mcp.Utils.RunToolSupportReadTest do
  use Rail.DataCase, async: true

  alias Rail.Mcp
  alias Rail.Mcp.RunContext
  alias Rail.Roles
  alias Rail.Tools.Schemas.OsProcess

  setup %{project: project} do
    {:ok, plan} = Roles.get_role(project_id: project.id, stage: :plan)
    task = learnings_task(project, "SRD-#{System.unique_integer([:positive])}", :plan)
    %{task: task, context: %RunContext{role: plan, os_process: %OsProcess{task_id: task.id}}}
  end

  test "reads the conversation the issue references as Support holds it now", %{
    project: project,
    task: task,
    context: context
  } do
    later = %{
      "id" => "p1",
      "part_type" => "comment",
      "created_at" => 1_790_000_050,
      "body" => "<p>It happens on the PDF too.</p>",
      "author" => %{"type" => "user", "name" => "Marta"}
    }

    conversation = support_conversation(project, [later])
    task.issue |> Ecto.Changeset.change(support_conversation_id: conversation.id) |> Repo.update!()

    assert {:ok, %{"content" => [%{"type" => "text", "text" => text}]}} = Mcp.call_run_tool(context, "support_read", %{})
    assert "The Intercom conversation with" <> _rest = text
    assert text =~ "**Marta** (customer)"
    assert text =~ "> Two bugs."
    assert text =~ "> It happens on the PDF too."
  end

  test "says so when the issue did not come from support", %{context: context} do
    assert {:ok, %{"content" => [%{"text" => "This issue was not created from a support conversation" <> _rest}]}} =
             Mcp.call_run_tool(context, "support_read", nil)
  end
end
