defmodule Rail.Pipeline.Actions.DecideQaFindingTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.QaFinding
  alias Rail.Roles

  setup %{project: project} do
    scope = system_scope()

    {:ok, role} = Roles.get_role(project_id: project.id, stage: :qa)

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_dcq_1", "identifier" => "DCQ-1", "title" => "Decide Qa"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "Decide Qa"})
    {:ok, task} = Pipeline.create_task(issue, :qa)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    {:ok, [finding]} =
      Pipeline.sync_qa_findings(task, [
        %{
          key: "total-unrounded",
          title: "The total renders as $1234.5",
          check: "A bill's total reads as money",
          severity: :major,
          recommendation: :fix,
          status: :open
        }
      ])

    %{task: task, role: role, finding: finding}
  end

  test "the human overrules QA", %{finding: finding} do
    assert {:ok, %QaFinding{recommendation: :fix, decision: :skip}} = Pipeline.decide_qa_finding(finding, :skip)
  end

  test "and can put it back", %{finding: finding} do
    {:ok, dismissed} = Pipeline.decide_qa_finding(finding, :skip)

    assert {:ok, %QaFinding{decision: :fix}} = Pipeline.decide_qa_finding(dismissed, :fix)
  end

  test "a task that has left QA has nothing left to decide", %{task: task, finding: finding} do
    {:ok, _moved} = Pipeline.update_task(task, %{stage: :demo})

    assert {:error, {:invalid_stage, :demo}} = Pipeline.decide_qa_finding(finding, :skip)
  end

  test "a finding is not ruled on while the run that raised it is still going", %{
    task: task,
    role: role,
    finding: finding
  } do
    {:ok, _run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :running,
        started_at: DateTime.utc_now()
      })

    assert {:error, :stage_running} = Pipeline.decide_qa_finding(finding, :skip)
  end
end
