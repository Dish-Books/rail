defmodule Rail.Mcp.Utils.RunToolCommitFixesTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Mcp
  alias Rail.Mcp.RunContext
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Roles
  alias Rail.Tools.Schemas.OsProcess

  # The round's own rules are `end_turn_and_commit_fixes`'s; this is only what the lead's call reaches and reads.
  setup %{project: project} do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_rcf_1", "identifier" => "RCF-1", "title" => "Commit Fixes"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Commit Fixes"})
    {:ok, task} = Pipeline.create_task(issue, :review)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    {:ok, role} = Roles.get_role(project_id: project.id, stage: :review_lead)

    {:ok, run} =
      Pipeline.create_run(%{task_id: task.id, role_id: role.id, status: :running, started_at: DateTime.utc_now()})

    os_process = %OsProcess{id: "proc_rcf", run_id: run.id, task_id: task.id}

    %{task: task, run: run, lead: %RunContext{os_process: os_process, role: role, user: nil}}
  end

  test "an accepted round says the turn is over and Rail is committing it", %{lead: lead, task: %{id: task_id}, run: run} do
    arguments = %{"message" => "Scope the round query", "findings" => [%{"key" => "round-query-scope"}]}

    expect(Pipeline, :end_turn_and_commit_fixes, fn %Task{id: ^task_id}, %OsProcess{id: "proc_rcf"}, ^arguments ->
      {:ok, :committing}
    end)

    assert {:ok,
            %{
              "content" => [
                %{
                  "text" =>
                    "Your turn is over. Rail is committing the fix round and running CI; the next round starts once it passes."
                }
              ]
            }} = Mcp.call_run_tool(lead, "commit_fixes", arguments)

    # A save is not logged: the transcript already shows the call.
    assert Pipeline.list_run_events(run) == []
  end

  test "a refused round comes back as the refusal, for the lead to settle", %{lead: lead} do
    expect(Pipeline, :end_turn_and_commit_fixes, fn %Task{}, %OsProcess{}, %{} ->
      {:refused, "Refused, nothing committed. the round leaves out round-query-scope, ruled Fix."}
    end)

    assert {:error, {:refused, "Refused, nothing committed. the round leaves out round-query-scope, ruled Fix."}} =
             Mcp.call_run_tool(lead, "commit_fixes", %{"message" => "Scope the round query", "findings" => []})
  end

  # The engineer commits through `commit`; a fix round is only ever the lead's to hand over.
  test "a role other than the Review lead is not offered it", %{lead: lead, project: project} do
    {:ok, engineer} = Roles.get_role(project_id: project.id, stage: :engineer)
    reject(Pipeline, :end_turn_and_commit_fixes, 3)

    assert {:error, :unknown_tool} = Mcp.call_run_tool(%{lead | role: engineer}, "commit_fixes", %{})
  end
end
