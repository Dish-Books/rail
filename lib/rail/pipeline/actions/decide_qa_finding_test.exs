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

    [finding] =
      for finding <- [
            %{
              key: "total-unrounded",
              title: "The total renders as $1234.5",
              check: "A bill's total reads as money",
              severity: :major,
              recommendation: :fix,
              status: :open,
              evidence: [%{name: "what QA saw", kind: :note, text: "Seen."}]
            }
          ] do
        {:ok, saved} = Pipeline.save_qa_finding(task, finding)

        saved
      end

    %{task: task, role: role, finding: finding}
  end

  test "the human overrules QA", %{finding: finding} do
    assert {:ok, %QaFinding{recommendation: :fix, decision: :skip}} =
             Pipeline.decide_qa_finding(system_scope(), finding, :skip)
  end

  test "and can put it back", %{finding: finding} do
    {:ok, dismissed} = Pipeline.decide_qa_finding(system_scope(), finding, :skip)

    assert {:ok, %QaFinding{decision: :fix}} = Pipeline.decide_qa_finding(system_scope(), dismissed, :fix)
  end

  test "a task that has left QA has nothing left to decide", %{task: task, finding: finding} do
    {:ok, _moved} = Pipeline.update_task(task, %{stage: :demo})

    assert {:error, {:invalid_stage, :demo}} = Pipeline.decide_qa_finding(system_scope(), finding, :skip)
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

    assert {:error, :stage_running} = Pipeline.decide_qa_finding(system_scope(), finding, :skip)
  end

  test "records who decided", %{finding: finding} do
    {:ok, %{id: user_id} = user} =
      Rail.Users.register_oauth_user(%{github_id: "dqf-u", login: "dana", name: "Dana", email: "dana@dqf.example"})

    assert {:ok, %{decision: :fix, decided_by_id: ^user_id}} =
             Pipeline.decide_qa_finding(Rail.Scope.for_user(user), finding, :fix)
  end
end
