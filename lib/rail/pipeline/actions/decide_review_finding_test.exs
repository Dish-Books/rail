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

    [finding] =
      for finding <- [
            %{key: "unhandled-nil", title: "Nil is not handled", severity: :major, recommendation: :fix, status: :open}
          ] do
        {:ok, saved} = Pipeline.save_review_finding(task, finding)

        saved
      end

    %{task: task, role: role, finding: finding}
  end

  test "the human overrules the reviewer", %{finding: finding} do
    assert {:ok, %ReviewFinding{recommendation: :fix, decision: :skip}} =
             Pipeline.decide_review_finding(system_scope(), finding, :skip)
  end

  test "and can put it back", %{finding: finding} do
    {:ok, dismissed} = Pipeline.decide_review_finding(system_scope(), finding, :skip)

    assert {:ok, %ReviewFinding{decision: :fix}} = Pipeline.decide_review_finding(system_scope(), dismissed, :fix)
  end

  test "a task that has left review has nothing left to decide", %{task: task, finding: finding} do
    {:ok, _moved} = Pipeline.update_task(task, %{stage: :qa})

    assert {:error, {:invalid_stage, :qa}} = Pipeline.decide_review_finding(system_scope(), finding, :skip)
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

    assert {:error, :stage_running} = Pipeline.decide_review_finding(system_scope(), finding, :skip)
  end

  test "records who decided, and learns nothing until the findings are sent", %{
    project: project,
    task: task,
    finding: finding
  } do
    {:ok, %{id: user_id} = user} =
      Rail.Users.register_oauth_user(%{github_id: "dcf-u", login: "dana", name: "Dana", email: "dana@dcf.example"})

    calibration = learning(project, %{rule: "Don't flag this", kind: :calibration})

    [_finding] =
      for finding <- [
            %{
              key: "unhandled-nil",
              title: "Nil is not handled",
              severity: :major,
              recommendation: :fix,
              status: :open,
              rule: calibration.id
            }
          ] do
        {:ok, saved} = Pipeline.save_review_finding(task, finding)

        saved
      end

    assert {:ok, %ReviewFinding{decision: :fix, decided_by_id: ^user_id}} =
             Pipeline.decide_review_finding(Rail.Scope.for_user(user), Repo.reload!(finding), :fix)

    assert [] = Repo.all(from o in Rail.Learnings.Schemas.Observation, where: o.task_id == ^task.id)
    assert [] = Repo.all(from p in Rail.Learnings.Schemas.LearningProposal, where: p.project_id == ^project.id)
    assert {:ok, [%{status: :active, flagged: false}]} = Rail.Learnings.list_learnings(ids: [calibration.id])
  end
end
