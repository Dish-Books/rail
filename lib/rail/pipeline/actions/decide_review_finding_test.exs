defmodule Rail.Pipeline.Actions.DecideReviewFindingTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.ReviewFinding
  alias Rail.Roles

  setup %{project: project} do
    scope = system_scope()

    {:ok, role} = Roles.get_role(project_id: project.id, stage: :review)

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_dcf_1", "identifier" => "DCF-1", "title" => "Decide Finding"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "Decide Finding"})
    {:ok, task} = Pipeline.create_task(issue, :review)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    {:ok, [finding]} =
      Pipeline.sync_review_findings(task, [
        %{key: "unhandled-nil", title: "Nil is not handled", severity: :major, recommendation: :fix, status: :open}
      ])

    %{task: task, role: role, finding: finding}
  end

  test "the human overrules the reviewer", %{finding: finding} do
    assert {:ok, %ReviewFinding{recommendation: :fix, decision: :skip}} =
             Pipeline.decide_review_finding(finding, :skip)
  end

  test "and can put it back", %{finding: finding} do
    {:ok, dismissed} = Pipeline.decide_review_finding(finding, :skip)

    assert {:ok, %ReviewFinding{decision: :fix}} = Pipeline.decide_review_finding(dismissed, :fix)
  end

  test "a task that has left review has nothing left to decide", %{task: task, finding: finding} do
    {:ok, _moved} = Pipeline.update_task(task, %{stage: :qa})

    assert {:error, {:invalid_stage, :qa}} = Pipeline.decide_review_finding(finding, :skip)
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

    assert {:error, :stage_running} = Pipeline.decide_review_finding(finding, :skip)
  end
end
