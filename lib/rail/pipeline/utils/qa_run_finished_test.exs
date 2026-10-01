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
  alias Rail.Tools.Schemas.OsProcess

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
      report_path: Path.join(qa_dir, "QFN-1.json")
    }
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
       "severity": "blocker", "recommendation": "fix", "status": "open",
       "evidence": [{"name": "the total", "kind": "query", "text": "total: 1234.5"}]}
    ]}
    """)

    reject(Tools, :start_os_process, 2)

    assert %Run{error: nil, evidence_reminders: 0} = qa_run_finished(run, [])
    assert %Task{stage: :qa} = Repo.reload!(task)

    assert [%QaFinding{key: "total-unrounded", severity: :blocker, decision: nil, screen: "/bills/new"}] =
             Pipeline.list_qa_findings(task)

    assert Pipeline.list_run_events(run) == []
  end

  test "a run that found nothing goes on to demo by itself", %{task: task, run: run, report_path: path} do
    File.write!(path, ~s({"verdict": "pass", "findings": []}))

    reject(Tools, :start_os_process, 2)

    assert %Run{error: nil, stage_outcome: :done} = qa_run_finished(run, [])
    assert %Task{stage: :demo} = Repo.reload!(task)
    assert Pipeline.list_qa_findings(task) == []
  end

  test "a re-test that finds everything fixed goes on to demo", %{task: task, run: run, report_path: path} do
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

    {:ok, _to_fix} = Pipeline.decide_qa_finding(finding, :fix)

    File.write!(path, """
    {"verdict": "pass", "findings": [
      {"key": "total-unrounded", "title": "The total renders as $1234.5",
       "check": "A bill's total reads as money", "severity": "major", "recommendation": "fix", "status": "fixed",
       "evidence": [{"name": "the total now", "kind": "query", "text": "total: 1,234.50"}]}
    ]}
    """)

    assert %Run{error: nil, stage_outcome: :done} = qa_run_finished(run, [])
    assert %Task{stage: :demo} = Repo.reload!(task)
  end

  test "a re-test that finds a fix still missing stays at QA", %{task: task, run: run, report_path: path} do
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

    {:ok, _to_fix} = Pipeline.decide_qa_finding(finding, :fix)

    File.write!(path, """
    {"verdict": "fail", "findings": [
      {"key": "total-unrounded", "title": "The total renders as $1234.5",
       "check": "A bill's total reads as money", "severity": "major", "recommendation": "fix", "status": "not_fixed",
       "evidence": [{"name": "the total still", "kind": "query", "text": "total: 1234.5"}]}
    ]}
    """)

    assert %Run{error: nil, stage_outcome: :in_progress} = qa_run_finished(run, [])
    assert %Task{stage: :qa} = Repo.reload!(task)
  end

  test "a message queued for QA holds a clean pass at QA", %{task: task, run: run, report_path: path} do
    File.write!(path, ~s({"verdict": "pass", "findings": []}))
    {:ok, queued} = Pipeline.update_run(run, %{pending_chat: "Try it on a phone too."})

    assert %Run{error: nil} = qa_run_finished(%{queued | task: run.task, role: run.role}, [])
    assert %Task{stage: :qa} = Repo.reload!(task)
  end

  test "a report with a finding that shows nothing goes back to QA, and nothing from it is recorded", %{
    task: task,
    run: run,
    report_path: path
  } do
    File.write!(path, """
    {"verdict": "fail", "findings": [
      {"key": "total-unrounded", "title": "The total renders as $1234.5", "check": "totals",
       "severity": "blocker", "recommendation": "fix",
       "evidence": [{"name": "the total", "kind": "query", "text": "total: 1234.5"}]},
      {"key": "export-button-enabled", "title": "Export button stays enabled while a download is in progress",
       "check": "export-progress", "severity": "minor", "recommendation": "fix"}
    ]}
    """)

    test_pid = self()

    expect(Tools, :start_os_process, fn spawned, argv ->
      send(test_pid, {:resumed, Enum.join(argv, " ")})
      {:ok, %OsProcess{run: spawned}}
    end)

    assert %Run{status: :running, stage_outcome: :in_progress, evidence_reminders: 1, error: nil} =
             qa_run_finished(run, [])

    assert %Task{stage: :qa} = Repo.reload!(task)
    assert Pipeline.list_qa_findings(task) == []

    assert_received {:resumed, prompt}
    assert prompt =~ "This report is not valid yet."
    assert prompt =~ "and 1 finding does not:"

    assert prompt =~
             "- Export button stays enabled while a download is in progress (export-button-enabled): no evidence attached."

    refute prompt =~ "(total-unrounded)"
    assert prompt =~ "write #{path} again"

    assert [
             "[rail] 1 finding had no evidence, so the report went back to QA (1 of 2).",
             "[reminder 1 of 2] This report is not valid yet." <> _opening
             | reminder
           ] = run |> Pipeline.list_run_events() |> Enum.map(& &1.line)

    assert Enum.all?(reminder, &String.starts_with?(&1, "[reminder 1 of 2]"))
    assert Enum.any?(reminder, &(&1 =~ "(export-button-enabled): no evidence attached."))
  end

  test "a finding whose only evidence Rail refused is sent back with why", %{
    task: task,
    run: run,
    report_path: path
  } do
    File.write!(path, """
    {"findings": [
      {"key": "export-decimal-comma", "title": "Exported amounts use a comma", "check": "locale",
       "severity": "major", "recommendation": "fix",
       "evidence": [{"name": "the export", "kind": "log", "path": "../../tmp/INV-2025-0412.csv"}]},
      {"key": "export-missing-log", "title": "The export log is missing", "check": "export",
       "severity": "major", "recommendation": "fix",
       "evidence": [{"name": "the log", "kind": "log", "path": "evidence/server.log"}]}
    ]}
    """)

    test_pid = self()

    expect(Tools, :start_os_process, fn spawned, argv ->
      send(test_pid, {:resumed, Enum.join(argv, " ")})
      {:ok, %OsProcess{run: spawned}}
    end)

    assert %Run{status: :running, evidence_reminders: 1} = qa_run_finished(run, [])
    assert Pipeline.list_qa_findings(task) == []

    assert_received {:resumed, prompt}
    assert prompt =~ "and 2 findings do not:"

    assert prompt =~
             "(export-decimal-comma): evidence refused: ../../tmp/INV-2025-0412.csv is outside the QA folder."

    assert prompt =~ "(export-missing-log): evidence refused: evidence/server.log is not a file in the QA folder."

    assert ["[rail] 2 findings had no evidence, so the report went back to QA (1 of 2)." | _note] =
             run |> Pipeline.list_run_events() |> Enum.map(& &1.line)
  end

  test "a report fixed after a reminder is recorded, and Rail says so", %{task: task, run: run, report_path: path} do
    {:ok, reminded} = Pipeline.update_run(run, %{evidence_reminders: 1})

    File.write!(path, """
    {"findings": [
      {"key": "export-button-enabled", "title": "Export button stays enabled", "check": "export-progress",
       "severity": "minor", "recommendation": "fix",
       "evidence": [{"name": "two downloads at once", "kind": "note", "text": "POST /exports twice"}]}
    ]}
    """)

    reject(Tools, :start_os_process, 2)

    assert %Run{evidence_reminders: 0, error: nil} = qa_run_finished(%{reminded | task: run.task, role: run.role}, [])
    assert [%QaFinding{key: "export-button-enabled"}] = Pipeline.list_qa_findings(task)

    assert ["[rail] Every finding carries evidence. 1 finding is ready for your call."] =
             run |> Pipeline.list_run_events() |> Enum.map(& &1.line)
  end

  test "a report still not valid after two reminders stops the asking", %{task: task, run: run, report_path: path} do
    {:ok, reminded} = Pipeline.update_run(run, %{evidence_reminders: 2})

    File.write!(path, """
    {"findings": [
      {"key": "export-button-enabled", "title": "Export button stays enabled", "check": "export-progress",
       "severity": "minor", "recommendation": "fix"},
      {"key": "export-decimal-comma", "title": "Exported amounts use a comma", "check": "locale",
       "severity": "major", "recommendation": "fix"}
    ]}
    """)

    reject(Tools, :start_os_process, 2)

    error = "QA's report still has 2 findings without evidence after 2 reminders. They are named in the QA sidebar."

    assert %Run{error: ^error, stage_outcome: :in_progress, status: :finished, evidence_reminders: 2} =
             qa_run_finished(%{reminded | task: run.task, role: run.role}, [])

    assert %Task{stage: :qa} = Repo.reload!(task)
    assert Pipeline.list_qa_findings(task) == []

    assert ["[rail] QA reported 2 findings without evidence after 2 reminders. Rail stopped asking."] =
             run |> Pipeline.list_run_events() |> Enum.map(& &1.line)
  end

  test "a reminder with dispatch off says QA was not resumed", %{run: run, report_path: path} do
    File.write!(path, """
    {"findings": [{"key": "bare", "title": "Bare", "check": "c", "severity": "nit", "recommendation": "skip"}]}
    """)

    expect(Tools, :start_os_process, fn _spawned, _argv -> {:error, :dispatch_disabled} end)

    assert %Run{status: :finished, evidence_reminders: 1, error: "Dispatch is off, so QA was not resumed."} =
             qa_run_finished(run, [])
  end

  test "a reminder that could not resume QA keeps why", %{run: run, report_path: path} do
    File.write!(path, """
    {"findings": [{"key": "bare", "title": "Bare", "check": "c", "severity": "nit", "recommendation": "skip"}]}
    """)

    expect(Tools, :start_os_process, fn spawned, _argv ->
      {:ok, failed} = Pipeline.update_run(spawned, %{status: :failed, error: "Failed to spawn runner: :enoent"})
      {:error, {:spawn_failed, :enoent, failed}}
    end)

    assert %Run{error: "Failed to spawn runner: :enoent"} = qa_run_finished(run, [])
    assert %Run{evidence_reminders: 1} = Repo.reload!(run)
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
