defmodule Rail.Pipeline.Utils.ReviewRunFinishedTest do
  use Rail.DataCase, async: true

  import Rail.Pipeline.Utils.ReviewRunFinished

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.ReviewFinding
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Roles
  alias Rail.Tools

  setup do
    scope = system_scope()

    {:ok, backend} = Tools.create_backend(scope, %{name: :claude, executable_path: "/usr/bin/true"})

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "lin_team_id"}]}}})
    end)

    {:ok, project} =
      Projects.create_project(scope, %{
        name: "Review Finished Project",
        github_repo: "org/review-finished",
        github_installation_id: 47_022,
        linear_workspace: %{
          name: "Review Finished Workspace",
          external_id: "lin_ws_review_finished",
          token: "lin_api_token_review_finished",
          webhook_secret: "whsec_review_finished"
        },
        linear_team_key: "RFN",
        default_branch: "main",
        clone_path: "/tmp/repos/review-finished",
        linear_state_ids: %{"triage" => "st_triage"}
      })

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
        status: :running,
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

    assert [%ReviewFinding{key: "unhandled-nil", severity: :blocker, decision: :fix}] =
             Pipeline.list_review_findings(task)
  end

  test "a run that found nothing leaves a task with nothing on it", %{task: task, run: run, report_path: path} do
    File.write!(path, ~s({"findings": []}))

    assert %Run{error: nil} = review_run_finished(run, [])
    assert Pipeline.list_review_findings(task) == []
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
