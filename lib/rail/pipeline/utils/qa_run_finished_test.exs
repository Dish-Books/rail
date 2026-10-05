defmodule Rail.Pipeline.Utils.QaRunFinishedTest do
  use Rail.DataCase, async: true

  import Rail.Pipeline.Utils.QaRunFinished

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.QaFinding
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Roles
  alias Rail.Tools

  setup %{project: project} do
    scope = system_scope()

    {:ok, role} = Roles.get_role(project_id: project.id, stage: :qa)

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
        # What `run_finished/3` hands over: the process has exited and the run is settled.
        status: :finished,
        conversation_id: "sess_qa_finished",
        started_at: DateTime.utc_now()
      })

    %{
      task: task,
      run: Repo.preload(run, [:task, role: :backend]),
      report_path: Path.join(qa_dir, "QFN-1.json"),
      finding: %{
        key: "total-unrounded",
        title: "The total renders as $1234.5",
        check: "A bill's total reads as money",
        severity: :major,
        recommendation: :fix,
        evidence: [%{name: "the total", kind: :query, text: "total: 1234.5"}]
      }
    }
  end

  test "a pass with a verdict and a finding to decide moves nothing and never resumes QA", %{
    task: task,
    run: run,
    finding: finding
  } do
    {:ok, _saved} = Pipeline.save_qa_finding(task, finding)
    {:ok, _verdict} = Pipeline.save_qa_verdict(task, %{verdict: :fail, summary: "The total is wrong."})

    reject(Tools, :start_os_process, 2)

    assert %Run{error: nil, status: :finished} = qa_run_finished(run, [])
    assert %Task{stage: :qa} = Repo.reload!(task)
    assert [%QaFinding{key: "total-unrounded", decision: nil}] = Pipeline.list_qa_findings(task)
    assert Pipeline.list_run_events(run) == []
  end

  test "a pass that found nothing goes on to demo by itself", %{task: task, run: run} do
    {:ok, _verdict} = Pipeline.save_qa_verdict(task, %{verdict: :pass, summary: "It works."})

    assert %Run{error: nil, stage_outcome: :done} = qa_run_finished(run, [])
    assert %Task{stage: :demo} = Repo.reload!(task)
  end

  test "a re-test that finds everything fixed goes on to demo", %{task: task, run: run, finding: finding} do
    {:ok, saved} = Pipeline.save_qa_finding(task, finding)
    {:ok, _to_fix} = Pipeline.decide_qa_finding(system_scope(), saved, :fix)
    {:ok, _fixed} = Pipeline.save_qa_finding(task, Map.put(finding, :status, :fixed))
    {:ok, _verdict} = Pipeline.save_qa_verdict(task, %{verdict: :pass, summary: "Fixed."})

    assert %Run{error: nil, stage_outcome: :done} = qa_run_finished(run, [])
    assert %Task{stage: :demo} = Repo.reload!(task)
  end

  test "a re-test that finds a fix still missing stays at QA", %{task: task, run: run, finding: finding} do
    {:ok, saved} = Pipeline.save_qa_finding(task, finding)
    {:ok, _to_fix} = Pipeline.decide_qa_finding(system_scope(), saved, :fix)
    {:ok, _not_fixed} = Pipeline.save_qa_finding(task, Map.put(finding, :status, :not_fixed))
    {:ok, _verdict} = Pipeline.save_qa_verdict(task, %{verdict: :fail, summary: "Still wrong."})

    assert %Run{error: nil, stage_outcome: :in_progress} = qa_run_finished(run, [])
    assert %Task{stage: :qa} = Repo.reload!(task)
  end

  test "a message queued for QA holds a clean pass at QA", %{task: task, run: run} do
    {:ok, _verdict} = Pipeline.save_qa_verdict(task, %{verdict: :pass, summary: "It works."})
    {:ok, queued} = Pipeline.update_run(run, %{pending_chat: "Try it on a phone too."})

    assert %Run{error: nil} = qa_run_finished(%{queued | task: run.task, role: run.role}, [])
    assert %Task{stage: :qa} = Repo.reload!(task)
  end

  test "a pass that saved findings but no verdict records that rather than reading as clean", %{
    task: task,
    run: run,
    finding: finding
  } do
    {:ok, _saved} = Pipeline.save_qa_finding(task, finding)

    assert %Run{error: "The QA agent did not save a verdict."} = qa_run_finished(run, [])
    assert %Task{stage: :qa} = Repo.reload!(task)
  end

  test "a report an old-brief agent wrote is no verdict, so the task stays at QA", %{
    task: task,
    run: run,
    report_path: path
  } do
    File.write!(path, ~s({"verdict": "pass", "summary": "Fine.", "findings": []}))

    assert %Run{error: "The QA agent did not save a verdict."} = qa_run_finished(run, [])
    assert %Task{stage: :qa} = Repo.reload!(task)
  end

  test "a verdict file Rail cannot read is no verdict", %{run: run, report_path: path} do
    File.write!(path, "It all looked fine to me.")

    assert %Run{error: "The QA agent did not save a verdict."} = qa_run_finished(run, [])
  end
end
