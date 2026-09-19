defmodule Rail.Mcp.Utils.RunToolQaPlanTest do
  use Rail.DataCase, async: true

  import Rail.Mcp.Utils.RunToolQaPlan

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Projects

  setup do
    scope = system_scope()

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "lin_team_id"}]}}})
    end)

    {:ok, project} =
      Projects.create_project(scope, %{
        name: "Qa Plan Project",
        github_repo: "org/qa-plan",
        github_installation_id: 47_051,
        linear_workspace: %{
          name: "Qa Plan Workspace",
          external_id: "lin_ws_qa_plan",
          token: "lin_api_token_qa_plan",
          webhook_secret: "whsec_qa_plan"
        },
        linear_team_key: "QPL",
        default_branch: "main",
        clone_path: "/tmp/repos/qa-plan",
        linear_state_ids: %{"triage" => "st_triage"}
      })

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_qpl_1", "identifier" => "QPL-1", "title" => "Qa Plan"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "Qa Plan"})
    {:ok, task} = Pipeline.create_task(issue, :qa)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    %{task: task}
  end

  test "writes the list and says how long it is", %{task: task} do
    assert {:ok, written} =
             run_tool_qa_plan(
               task,
               %{
                 "checks" => [
                   %{"key" => "bill-saves", "title" => "A bill saves"},
                   %{"key" => "totals", "title" => "The totals agree", "criterion" => "Totals match"}
                 ]
               },
               []
             )

    assert written =~ "2 checks"
    assert {:ok, %{checks: [%{key: "bill-saves"}, %{key: "totals"}]}} = Pipeline.read_qa_checklist(task)
  end

  # An outcome in the plan is not a check anybody ran, and neither is an entry
  # that is not a check at all.
  test "only what a pass may state is taken off what arrived", %{task: task} do
    assert {:ok, _written} =
             run_tool_qa_plan(
               task,
               %{
                 "checks" => [
                   "not a check at all",
                   %{"key" => "totals", "title" => "The totals agree", "outcome" => "pass"}
                 ]
               },
               []
             )

    assert {:ok, %{checks: [%{key: "totals", outcome: :pending}]}} = Pipeline.read_qa_checklist(task)
  end

  # Nothing an agent can get wrong is an error: it reads the answer and puts it
  # right on the next call.
  test "a list Rail cannot use is refused in words, and nothing is written", %{task: task} do
    assert {:ok, refused} = run_tool_qa_plan(task, %{"checks" => [%{"title" => "No key on this one"}]}, [])
    assert refused =~ "not usable"

    assert {:ok, "qa_plan needs a `checks` list. Nothing was written."} = run_tool_qa_plan(task, %{}, [])

    assert {:error, :qa_checklist_not_found} = Pipeline.read_qa_checklist(task)
  end
end
