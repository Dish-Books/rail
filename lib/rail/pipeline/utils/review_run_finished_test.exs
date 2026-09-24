defmodule Rail.Pipeline.Utils.ReviewRunFinishedTest do
  use Rail.DataCase, async: true

  import Rail.Pipeline.Utils.ReviewRunFinished

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.ReviewFinding
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Roles
  alias Rail.Tools

  setup %{project: project} do
    scope = system_scope()

    {:ok, backend} = Tools.create_backend(scope, %{name: :claude, executable_path: "/usr/bin/true"})

    {:ok, role} =
      Roles.create_role(scope, project, %{
        backend_id: backend.id,
        stage: :review,
        name: "review role",
        model: "claude-3-7-sonnet",
        system_prompt: "You are the review agent."
      })

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
    reviews_dir = Path.join(task.scratch_path, "reviews")
    File.mkdir_p!(reviews_dir)
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

    %{task: task, run: Repo.preload(run, [:task, :role]), report_path: Path.join(reviews_dir, "RFN-1.json")}
  end

  test "a run that reported records its findings and moves nothing", %{
    task: task,
    run: run,
    report_path: path
  } do
    File.write!(path, """
    {"findings": [
      {"key": "unhandled-nil", "title": "Nil is not handled", "detail": "The clause assumes a map.",
       "file": "lib/rail/example.ex", "line": 12, "severity": "blocker", "recommendation": "fix", "status": "open"}
    ]}
    """)

    assert %Run{error: nil} = review_run_finished(run, [])
    assert %Task{stage: :review} = Repo.reload!(task)

    assert [%ReviewFinding{key: "unhandled-nil", severity: :blocker, decision: nil}] =
             Pipeline.list_review_findings(task)
  end

  test "a run that found nothing goes on to QA by itself", %{task: task, run: run, report_path: path} do
    File.write!(path, ~s({"findings": []}))

    assert %Run{error: nil, stage_outcome: :done} = review_run_finished(run, [])
    assert %Task{stage: :qa} = Repo.reload!(task)
    assert Pipeline.list_review_findings(task) == []
  end

  test "a re-review that finds everything fixed goes on to QA", %{task: task, run: run, report_path: path} do
    {:ok, [finding]} =
      Pipeline.sync_review_findings(task, [
        %{key: "unhandled-nil", title: "Nil is not handled", severity: :major, recommendation: :fix, status: :open}
      ])

    {:ok, _to_fix} = Pipeline.decide_review_finding(finding, :fix)

    File.write!(path, """
    {"findings": [
      {"key": "unhandled-nil", "title": "Nil is not handled", "severity": "major", "recommendation": "fix",
       "status": "fixed"}
    ]}
    """)

    assert %Run{error: nil, stage_outcome: :done} = review_run_finished(run, [])
    assert %Task{stage: :qa} = Repo.reload!(task)
  end

  # A finding the human already dismissed is closed however the reviewer restates
  # it, so it does not hold the change at review.
  test "a re-review that leaves only what the human dismissed goes on to QA", %{
    task: task,
    run: run,
    report_path: path
  } do
    {:ok, [finding]} =
      Pipeline.sync_review_findings(task, [
        %{key: "long-name", title: "The name is long", severity: :nit, recommendation: :skip, status: :open}
      ])

    {:ok, _dismissed} = Pipeline.decide_review_finding(finding, :skip)

    File.write!(path, """
    {"findings": [
      {"key": "long-name", "title": "The name is long", "severity": "nit", "recommendation": "skip",
       "status": "not_fixed"}
    ]}
    """)

    assert %Run{error: nil} = review_run_finished(run, [])
    assert %Task{stage: :qa} = Repo.reload!(task)
  end

  test "a re-review that finds a fix still missing stays at review", %{task: task, run: run, report_path: path} do
    {:ok, [finding]} =
      Pipeline.sync_review_findings(task, [
        %{key: "unhandled-nil", title: "Nil is not handled", severity: :major, recommendation: :fix, status: :open}
      ])

    {:ok, _to_fix} = Pipeline.decide_review_finding(finding, :fix)

    File.write!(path, """
    {"findings": [
      {"key": "unhandled-nil", "title": "Nil is not handled", "severity": "major", "recommendation": "fix",
       "status": "not_fixed"}
    ]}
    """)

    assert %Run{error: nil, stage_outcome: :in_progress} = review_run_finished(run, [])
    assert %Task{stage: :review} = Repo.reload!(task)
  end

  # The reviewer recommending a finding be let stand is still a finding: whether
  # to live with it is the human's call, not the reviewer's.
  test "a run whose only finding it would skip still waits on the human", %{
    task: task,
    run: run,
    report_path: path
  } do
    File.write!(path, """
    {"findings": [
      {"key": "long-name", "title": "The name is long", "severity": "nit", "recommendation": "skip"}
    ]}
    """)

    assert %Run{error: nil} = review_run_finished(run, [])
    assert %Task{stage: :review} = Repo.reload!(task)
  end

  test "a message queued for the reviewer holds a clean review at review", %{
    task: task,
    run: run,
    report_path: path
  } do
    File.write!(path, ~s({"findings": []}))
    {:ok, queued} = Pipeline.update_run(run, %{pending_chat: "Look at the migration too."})

    assert %Run{error: nil} = review_run_finished(%{queued | task: run.task, role: run.role}, [])
    assert %Task{stage: :review} = Repo.reload!(task)
  end

  test "a run that exited without a report records that rather than reading as clean", %{
    task: task,
    run: run
  } do
    assert %Run{error: "The reviewer did not write reviews/RFN-1.json."} = review_run_finished(run, [])
    assert %Task{stage: :review} = Repo.reload!(task)
  end

  test "a report Rail cannot read is no report", %{run: run, report_path: path} do
    File.write!(path, "Looks fine to me.")

    assert %Run{error: "The reviewer did not write reviews/RFN-1.json."} = review_run_finished(run, [])
  end
end
