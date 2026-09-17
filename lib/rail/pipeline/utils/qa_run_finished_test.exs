defmodule Rail.Pipeline.Utils.QaRunFinishedTest do
  use Rail.DataCase, async: true

  import Rail.Pipeline.Utils.QaRunFinished

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.QaFinding
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
        name: "Qa Finished Project",
        github_repo: "org/qa-finished",
        github_installation_id: 47_037,
        linear_workspace: %{
          name: "Qa Finished Workspace",
          external_id: "lin_ws_qa_finished",
          token: "lin_api_token_qa_finished",
          webhook_secret: "whsec_qa_finished"
        },
        linear_team_key: "QFN",
        default_branch: "main",
        clone_path: "/tmp/repos/qa-finished",
        linear_state_ids: %{"triage" => "st_triage"}
      })

    {:ok, role} =
      Roles.create_role(scope, project, %{
        backend_id: backend.id,
        stage: :qa,
        name: "qa role",
        model: "claude-3-7-sonnet",
        system_prompt: "You are the QA agent."
      })

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_qfn_1", "identifier" => "QFN-1", "title" => "Qa Finished"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "Qa Finished"})
    {:ok, task} = Pipeline.create_task(issue, :qa)
    qa_dir = Path.join(task.scratch_path, "qa")
    File.mkdir_p!(qa_dir)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :running,
        conversation_id: "sess_qa_finished",
        started_at: DateTime.utc_now()
      })

    %{task: task, run: Repo.preload(run, [:task, :role]), report_path: Path.join(qa_dir, "QFN-1.json")}
  end

  test "a run that reported records its findings and moves nothing", %{
    task: task,
    run: run,
    report_path: path
  } do
    File.write!(path, """
    {"verdict": "fail", "summary": "The total is wrong.", "findings": [
      {"key": "total-unrounded", "title": "The total renders as $1234.5",
       "check": "A bill's total reads as money", "screen": "/bills/new",
       "severity": "blocker", "recommendation": "fix", "status": "open"}
    ]}
    """)

    assert %Run{error: nil} = qa_run_finished(run, [])
    assert %Task{stage: :qa} = Repo.reload!(task)

    assert [%QaFinding{key: "total-unrounded", severity: :blocker, decision: nil, screen: "/bills/new"}] =
             Pipeline.list_qa_findings(task)
  end

  test "a run that found nothing leaves a task with nothing on it", %{task: task, run: run, report_path: path} do
    File.write!(path, ~s({"verdict": "pass", "findings": []}))

    assert %Run{error: nil} = qa_run_finished(run, [])
    assert Pipeline.list_qa_findings(task) == []
  end

  test "a run that exited without a report records that rather than reading as clean", %{
    task: task,
    run: run
  } do
    assert %Run{error: "The QA agent did not write qa/QFN-1.json."} = qa_run_finished(run, [])
    assert %Task{stage: :qa} = Repo.reload!(task)
  end

  test "a report Rail cannot read is no report", %{run: run, report_path: path} do
    File.write!(path, "It all looked fine to me.")

    assert %Run{error: "The QA agent did not write qa/QFN-1.json."} = qa_run_finished(run, [])
  end
end
