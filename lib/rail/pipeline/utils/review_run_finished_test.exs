defmodule Rail.Pipeline.Utils.ReviewRunFinishedTest do
  use Rail.DataCase, async: true

  import Rail.Pipeline.Utils.ReviewRunFinished

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.ReviewFinding
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
            "issue" => %{"id" => "lin_rfn_1", "identifier" => "RFN-1", "title" => "Review Finished"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "Review Finished"})
    {:ok, task} = Pipeline.create_task(issue, :review)
    # Going on to QA starts its run, which works in the worktree.
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: create_temp_git_repo()})
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        # What `run_finished/3` hands over: the process has exited and the run is settled.
        status: :finished,
        conversation_id: "sess_review_finished",
        started_at: DateTime.utc_now()
      })

    %{
      task: task,
      run: Repo.preload(run, [:task, :role]),
      report_path: Path.join([task.scratch_path, "reviews", "RFN-1.json"]),
      finding: %{key: "unhandled-nil", title: "Nil is not handled", severity: :major, recommendation: :fix}
    }
  end

  test "a closed pass with a finding to decide moves nothing", %{task: task, run: run, finding: finding} do
    {:ok, _saved} = Pipeline.save_review_finding(task, finding)
    {:ok, _closed} = Pipeline.save_review(task)

    assert %Run{error: nil} = review_run_finished(run, [])
    assert %Task{stage: :review} = Repo.reload!(task)
    assert [%ReviewFinding{key: "unhandled-nil", decision: nil}] = Pipeline.list_review_findings(task)
  end

  test "a closed pass that found nothing goes on to QA by itself", %{task: task, run: run} do
    {:ok, _closed} = Pipeline.save_review(task)

    assert %Run{error: nil, stage_outcome: :done} = review_run_finished(run, [])
    assert %Task{stage: :qa} = Repo.reload!(task)
  end

  test "a re-review that finds everything fixed goes on to QA", %{task: task, run: run, finding: finding} do
    {:ok, saved} = Pipeline.save_review_finding(task, finding)
    {:ok, _to_fix} = Pipeline.decide_review_finding(system_scope(), saved, :fix)
    {:ok, _fixed} = Pipeline.save_review_finding(task, Map.put(finding, :status, :fixed))
    {:ok, _closed} = Pipeline.save_review(task)

    assert %Run{error: nil, stage_outcome: :done} = review_run_finished(run, [])
    assert %Task{stage: :qa} = Repo.reload!(task)
  end

  # A finding the human already dismissed is closed however the reviewer restates
  # it, so it does not hold the change at review.
  test "a re-review that leaves only what the human dismissed goes on to QA", %{task: task, run: run} do
    long_name = %{key: "long-name", title: "The name is long", severity: :nit, recommendation: :skip}
    {:ok, saved} = Pipeline.save_review_finding(task, long_name)
    {:ok, _dismissed} = Pipeline.decide_review_finding(system_scope(), saved, :skip)
    {:ok, _restated} = Pipeline.save_review_finding(task, Map.put(long_name, :status, :not_fixed))
    {:ok, _closed} = Pipeline.save_review(task)

    assert %Run{error: nil} = review_run_finished(run, [])
    assert %Task{stage: :qa} = Repo.reload!(task)
  end

  test "a re-review that finds a fix still missing stays at review", %{task: task, run: run, finding: finding} do
    {:ok, saved} = Pipeline.save_review_finding(task, finding)
    {:ok, _to_fix} = Pipeline.decide_review_finding(system_scope(), saved, :fix)
    {:ok, _not_fixed} = Pipeline.save_review_finding(task, Map.put(finding, :status, :not_fixed))
    {:ok, _closed} = Pipeline.save_review(task)

    assert %Run{error: nil, stage_outcome: :in_progress} = review_run_finished(run, [])
    assert %Task{stage: :review} = Repo.reload!(task)
  end

  test "a message queued for the reviewer holds a clean review at review", %{task: task, run: run} do
    {:ok, _closed} = Pipeline.save_review(task)
    {:ok, queued} = Pipeline.update_run(run, %{pending_chat: "Look at the migration too."})

    assert %Run{error: nil} = review_run_finished(%{queued | task: run.task, role: run.role}, [])
    assert %Task{stage: :review} = Repo.reload!(task)
  end

  test "a pass that saved findings but never closed records that rather than reading as clean", %{
    task: task,
    run: run,
    finding: finding
  } do
    {:ok, _saved} = Pipeline.save_review_finding(task, finding)

    assert %Run{error: "The reviewer did not save its review."} = review_run_finished(run, [])
    assert %Task{stage: :review} = Repo.reload!(task)
  end

  test "a report written before this change still closes the review", %{task: task, run: run, report_path: path} do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, ~s({"findings": []}))

    assert %Run{error: nil, stage_outcome: :done} = review_run_finished(run, [])
    assert %Task{stage: :qa} = Repo.reload!(task)
  end
end
