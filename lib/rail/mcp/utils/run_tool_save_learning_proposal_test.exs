defmodule Rail.Mcp.Utils.RunToolSaveLearningProposalTest do
  use Rail.DataCase, async: true

  alias Rail.Learnings
  alias Rail.Learnings.Schemas.Learning
  alias Rail.Learnings.Schemas.LearningProposal
  alias Rail.Mcp
  alias Rail.Mcp.RunContext
  alias Rail.Pipeline
  alias Rail.Roles
  alias Rail.Tools.Schemas.OsProcess

  setup %{project: project} do
    task = learnings_task(project, "RTSLP-1", :finalize)
    {:ok, curator} = Roles.get_role(project_id: project.id, stage: :curator)
    %{task: task, context: %RunContext{role: curator, os_process: %OsProcess{task_id: task.id}}}
  end

  test "an add is saved as a pending proposal of the task's, and its id told to the agent", %{
    task: %{id: task_id} = task,
    context: context
  } do
    arguments = %{
      "action" => "add",
      "title" => "Broadcast after commit",
      "rule" => "Broadcast after the write commits.",
      "kind" => "convention",
      "roles" => ["engineer", 7],
      "path_glob" => "lib/rail/pipeline/**",
      "why" => 42
    }

    assert {:ok, %{"content" => [%{"text" => "Saved as lpr_" <> _rest}]}} =
             Mcp.call_run_tool(context, "save_learning_proposal", arguments)

    assert [
             %LearningProposal{
               action: :add,
               task_id: ^task_id,
               status: :pending,
               title: "Broadcast after commit",
               learning: %Learning{status: :proposed, roles: [:engineer], path_glob: "lib/rail/pipeline/**", why: nil}
             }
           ] = Learnings.list_learning_proposals(task_id: task.id)
  end

  test "a revise of a decided proposal, an unknown id, a bad action and a bad draft are each refused", %{
    task: task,
    context: context
  } do
    {:ok, proposal} = Learnings.save_task_proposal(task, %{action: "add", rule: "Lock the row", kind: "convention"})
    {:ok, _approved} = Learnings.approve_learning_proposal(system_scope(), proposal)

    assert {:error, {:refused, "Nothing saved: a person already decided that proposal" <> _rest}} =
             Mcp.call_run_tool(context, "save_learning_proposal", %{"proposal" => proposal.id, "title" => "Narrow"})

    assert {:error, {:refused, "Nothing saved: no active or provisional rule" <> _rest}} =
             Mcp.call_run_tool(context, "save_learning_proposal", %{"action" => "retire", "target" => "lrn_gone"})

    assert {:error, {:refused, "Nothing saved: `action` is add, rewrite or retire" <> _rest}} =
             Mcp.call_run_tool(context, "save_learning_proposal", %{"action" => "merge"})

    assert {:error, {:refused, "Refused, nothing saved. rule: is required." <> _rest}} =
             Mcp.call_run_tool(context, "save_learning_proposal", %{"action" => "add", "kind" => "convention"})

    assert {:ok, %LearningProposal{status: :approved}} = Learnings.get_learning_proposal(proposal.id)
    assert {:ok, [_approved_rule]} = Learnings.list_learnings(project_id: task.project_id, status: :active)
  end

  test "a role not offered the tool cannot call it", %{task: task, project: project} do
    {:ok, engineer} = Roles.get_role(project_id: project.id, stage: :engineer)
    context = %RunContext{role: engineer, os_process: %OsProcess{task_id: task.id}}

    assert {:error, :unknown_tool} =
             Mcp.call_run_tool(context, "save_learning_proposal", %{"action" => "add", "rule" => "x"})

    assert [] = Learnings.list_learning_proposals(task_id: task.id)
    assert {:ok, _task} = Pipeline.get_task(task.id)
  end
end
