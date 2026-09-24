defmodule Rail.Pipeline.Actions.SendQaFindingsToEngineerTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess

  setup %{project: project} do
    scope = system_scope()

    {:ok, backend} = Tools.create_backend(scope, %{name: :claude, executable_path: "/usr/bin/true"})

    roles =
      Map.new([:engineer, :qa], fn stage ->
        {:ok, role} =
          Roles.create_role(scope, project, %{
            backend_id: backend.id,
            stage: stage,
            name: "#{stage} role",
            model: "claude-3-7-sonnet",
            system_prompt: "You are the #{stage} agent."
          })

        {stage, role}
      end)

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_sqf_1", "identifier" => "SQF-1", "title" => "Send Qa Findings"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "Send Qa Findings"})
    {:ok, task} = Pipeline.create_task(issue, :qa)
    worktree_path = create_temp_git_repo()
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: worktree_path})
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    {:ok, engineer_run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:engineer].id,
        status: :finished,
        stage_outcome: :done,
        conversation_id: "sess_send_qa_engineer",
        started_at: DateTime.utc_now()
      })

    {:ok, qa_run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:qa].id,
        status: :finished,
        stage_outcome: :in_progress,
        conversation_id: "sess_send_qa_qa",
        started_at: DateTime.utc_now()
      })

    {:ok, raised} =
      Pipeline.sync_qa_findings(task, [
        %{
          key: "total-unrounded",
          title: "The bill total renders as $1234.5",
          check: "A bill's total reads as money on the bill page",
          criterion: "Totals read as money",
          screen: "/bills/new",
          steps: "1. Open a new bill\n2. Enter 1234.50",
          expected: "$1,234.50",
          observed: "$1234.5",
          detail: "Every bill screen reads this way.",
          suggestion: "Format it with Money.to_string/1.",
          severity: :major,
          recommendation: :fix,
          status: :open,
          evidence: [
            %{name: "the total", kind: :screenshot, path: "evidence/total.png"},
            %{name: "the stored amount", kind: :query, text: "1234.50"}
          ]
        },
        %{
          key: "spacing-nit",
          title: "The save button sits too close to cancel",
          check: "The bill form looks like the rest of the app",
          severity: :nit,
          recommendation: :skip,
          status: :open
        }
      ])

    # Nothing is decided until a person decides it, so the fixture rules the way
    # QA advised and each test changes only what it is about.
    findings =
      Enum.map(raised, fn finding ->
        {:ok, decided} = Pipeline.decide_qa_finding(finding, finding.recommendation)
        decided
      end)

    %{
      task: task,
      engineer_run: engineer_run,
      qa_run: Repo.preload(qa_run, [:task, :role]),
      findings: findings
    }
  end

  test "hands the task to the engineer and latches the QA run", %{task: task, qa_run: run} do
    assert {:ok, %Run{stage_outcome: :done}} = Pipeline.send_qa_findings_to_engineer(run)
    assert %Task{stage: :engineer} = Repo.reload!(task)
  end

  test "the engineer is told only what the human chose to address, and how to see it", %{qa_run: run} do
    expect(Tools, :start_os_process, fn %Run{} = spawned, argv ->
      assert ["-p", prompt | _rest] = argv
      assert prompt =~ ~s(<finding key="total-unrounded" severity="major" screen="/bills/new">)
      assert prompt =~ "The bill total renders as $1234.5"
      assert prompt =~ "Found by: A bill's total reads as money on the bill page"
      assert prompt =~ "Fails acceptance criterion: Totals read as money"
      assert prompt =~ "Steps to reproduce: 1. Open a new bill"
      assert prompt =~ "Expected: $1,234.50"
      assert prompt =~ "Observed: $1234.5"
      assert prompt =~ "Evidence: the total (screenshot); the stored amount - 1234.50"
      assert prompt =~ "Suggested fix: Format it with Money.to_string/1."
      assert prompt =~ "</finding>"
      assert prompt =~ "Continue from where you stopped."
      refute prompt =~ "The save button sits too close to cancel"

      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %Run{}} = Pipeline.send_qa_findings_to_engineer(run)
  end

  # The pending answer is consumed by the spawn, so without this the engineer
  # starts working again with nothing in its conversation saying why.
  # A field QA left blank is a field it had nothing to say in, and a labelled
  # heading over nothing reads as something lost in transit.
  test "a section QA left blank is left out rather than sent empty", %{task: task, qa_run: run} do
    {:ok, findings} =
      Pipeline.sync_qa_findings(task, [
        %{
          key: "total-unrounded",
          title: "The bill total renders as $1234.5",
          check: "A bill's total reads as money",
          steps: "   ",
          severity: :major,
          recommendation: :fix,
          status: :open
        }
      ])

    Enum.each(findings, fn finding -> {:ok, _fix} = Pipeline.decide_qa_finding(finding, :fix) end)

    expect(Tools, :start_os_process, fn %Run{} = spawned, argv ->
      assert ["-p", prompt | _rest] = argv
      assert prompt =~ "Found by: A bill's total reads as money"
      refute prompt =~ "Steps to reproduce"

      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %Run{}} = Pipeline.send_qa_findings_to_engineer(run)
  end

  test "what was sent is written to the engineer's log", %{engineer_run: engineer_run, qa_run: run} do
    assert {:ok, %Run{}} = Pipeline.send_qa_findings_to_engineer(run)

    log = engineer_run |> Pipeline.list_run_events() |> Enum.map_join("\n", & &1.line)

    assert log =~ "[human] QA drove the running application against this ticket"
    assert log =~ "Reproduce each one before you change anything"
    assert log =~ "The bill total renders as $1234.5"
    refute log =~ "The save button sits too close to cancel"
  end

  test "a finding the human put back is sent too", %{qa_run: run, findings: findings} do
    nit = Enum.find(findings, &(&1.key == "spacing-nit"))
    {:ok, _kept} = Pipeline.decide_qa_finding(nit, :fix)

    expect(Tools, :start_os_process, fn %Run{} = spawned, argv ->
      assert ["-p", prompt | _rest] = argv
      assert prompt =~ "The save button sits too close to cancel"

      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %Run{}} = Pipeline.send_qa_findings_to_engineer(run)
  end

  # Sending while one is undecided would drop it from the round with nobody
  # having said to.
  test "nothing is sent while a finding has no ruling on it", %{task: task, qa_run: run} do
    {:ok, _undecided} =
      Pipeline.sync_qa_findings(task, [
        %{key: "brand-new", title: "New", check: "A check", severity: :minor, recommendation: :fix, status: :open}
      ])

    assert {:error, :findings_undecided} = Pipeline.send_qa_findings_to_engineer(run)
    assert %Task{stage: :qa} = Repo.reload!(task)
  end

  test "there is nothing to send when everything was dismissed", %{task: task, qa_run: run, findings: findings} do
    for finding <- findings, do: {:ok, _dismissed} = Pipeline.decide_qa_finding(finding, :skip)

    assert {:error, :nothing_outstanding} = Pipeline.send_qa_findings_to_engineer(run)
    assert %Task{stage: :qa} = Repo.reload!(task)
  end

  test "a task that has left QA has nothing left to send", %{task: task, qa_run: run} do
    {:ok, _moved} = Pipeline.update_task(task, %{stage: :demo})

    assert {:error, {:invalid_stage, :demo}} = Pipeline.send_qa_findings_to_engineer(run)
  end

  test "nothing is sent while something is still running", %{task: task, qa_run: run} do
    {:ok, _running} = Pipeline.update_run(run, %{status: :running})

    assert {:error, :stage_running} = Pipeline.send_qa_findings_to_engineer(Repo.reload!(run))
    assert %Task{stage: :qa} = Repo.reload!(task)
  end

  test "a project with no engineer has nobody to send them to", %{qa_run: run, task: task} do
    {:ok, engineer} = Roles.get_role(project_id: task.project_id, stage: :engineer)
    Repo.delete_all(from r in Run, where: r.role_id == ^engineer.id)
    {:ok, _deleted} = Roles.delete_role(system_scope(), engineer)

    assert {:error, :no_engineer_role} = Pipeline.send_qa_findings_to_engineer(run)
  end

  # The engineer may never have run: a task can reach QA with the change pushed
  # by a person rather than by an agent.
  test "an engineer that has never run is still handed the findings", %{
    engineer_run: engineer_run,
    qa_run: run,
    task: task
  } do
    Repo.delete!(engineer_run)

    expect(Tools, :start_os_process, fn %Run{} = spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)

    assert {:ok, %Run{}} = Pipeline.send_qa_findings_to_engineer(run)
    assert %Task{stage: :engineer} = Repo.reload!(task)
  end
end
