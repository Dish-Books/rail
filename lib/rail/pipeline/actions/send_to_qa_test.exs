defmodule Rail.Pipeline.Actions.SendToQaTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Roles

  setup %{project: project} do
    scope = system_scope()

    {:ok, role} = Roles.get_role(project_id: project.id, stage: :review)

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_sqa_1", "identifier" => "SQA-1", "title" => "Send To QA"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "Send To QA"})
    {:ok, task} = Pipeline.create_task(issue, :review)
    # Going on to QA starts its run, which works in the worktree.
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: create_temp_git_repo()})
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :finished,
        stage_outcome: :in_progress,
        conversation_id: "sess_send_to_qa",
        started_at: DateTime.utc_now()
      })

    raised = %{
      key: "unhandled-nil",
      title: "Nil is not handled",
      severity: :major,
      recommendation: :fix,
      status: :open
    }

    %{task: task, run: Repo.preload(run, [:task, :role]), raised: raised}
  end

  test "a review that raised nothing goes straight on", %{task: task, run: run} do
    assert {:ok, %Run{stage_outcome: :done}} = Pipeline.send_to_qa(run)
    assert %Task{stage: :qa} = Repo.reload!(task)
  end

  test "findings the engineer fixed are not outstanding", %{task: task, run: run, raised: raised} do
    {:ok, _synced} = Pipeline.sync_review_findings(task, [%{raised | status: :fixed}])

    assert {:ok, %Run{stage_outcome: :done}} = Pipeline.send_to_qa(run)
    assert %Task{stage: :qa} = Repo.reload!(task)
  end

  test "findings the human dismissed are not outstanding either", %{task: task, run: run, raised: raised} do
    {:ok, [finding]} = Pipeline.sync_review_findings(task, [raised])
    {:ok, _dismissed} = Pipeline.decide_review_finding(finding, :skip)

    assert {:ok, %Run{stage_outcome: :done}} = Pipeline.send_to_qa(run)
    assert %Task{stage: :qa} = Repo.reload!(task)
  end

  test "a change with something still to fix does not go on", %{task: task, run: run, raised: raised} do
    {:ok, [finding]} = Pipeline.sync_review_findings(task, [raised])
    {:ok, _to_fix} = Pipeline.decide_review_finding(finding, :fix)

    assert {:error, :findings_outstanding} = Pipeline.send_to_qa(run)
    assert %Task{stage: :review} = Repo.reload!(task)
  end

  # Silence is not a dismissal, so a finding nobody has ruled on holds the change
  # here rather than going quietly to QA.
  test "a finding nobody has ruled on does not go on either", %{task: task, run: run, raised: raised} do
    {:ok, _synced} = Pipeline.sync_review_findings(task, [raised])

    assert {:error, :findings_undecided} = Pipeline.send_to_qa(run)
    assert %Task{stage: :review} = Repo.reload!(task)
  end

  test "a task that has left review has nothing left to send", %{task: task, run: run} do
    {:ok, _moved} = Pipeline.update_task(task, %{stage: :engineer})

    assert {:error, {:invalid_stage, :engineer}} = Pipeline.send_to_qa(run)
  end

  test "nothing is sent while something is still running", %{task: task, run: run} do
    {:ok, _running} = Pipeline.update_run(run, %{status: :running})

    assert {:error, :stage_running} = Pipeline.send_to_qa(run)
    assert %Task{stage: :review} = Repo.reload!(task)
  end
end
