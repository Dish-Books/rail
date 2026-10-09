defmodule Rail.Pipeline.Actions.StartFixRoundTest do
  use Rail.DataCase, async: true

  alias Rail.GitHub.Client
  alias Rail.Issues
  alias Rail.Learnings.Schemas.Observation
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Finding
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess

  setup %{project: project} do
    {:ok, role} = Roles.get_role(project_id: project.id, stage: :review_lead)

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_sfr_1", "identifier" => "SFR-1", "title" => "Start Fix Round"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Start Fix Round"})
    {:ok, task} = Pipeline.create_task(issue, :review)
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: create_temp_git_repo(), pr_number: 9, pr_is_draft: true})
    task = Repo.preload(task, :issue)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :finished,
        stage_outcome: :done,
        conversation_id: "sess_sfr",
        started_at: DateTime.utc_now()
      })

    attrs = %{
      kind: :code,
      raised_by: :code_reviewer,
      problem: "It crashes.",
      file: "lib/a.ex",
      line: 3,
      fix: "Guard it.",
      why: "It crashes.",
      rule: "Every caller handles nil.",
      severity: :major,
      recommendation: :fix,
      places: [%{file: "lib/a.ex", line: 3, label: "handle/1"}, %{file: "lib/b.ex", line: 9}],
      evidence: [%{name: "range", kind: :code, file: "lib/a.ex", line: 3}]
    }

    {:ok, crash} = Pipeline.save_finding(task, Map.merge(attrs, %{key: "nil-crash", title: "Nil crashes the page"}))
    {:ok, nit} = Pipeline.save_finding(task, Map.merge(attrs, %{key: "a-nit", title: "A nit", severity: :nit}))
    {:ok, %{round: 1}} = Pipeline.save_review(task)

    %{task: task, run: run, crash: crash, nit: nit}
  end

  test "it is refused while any finding is undecided", %{run: run, crash: crash} do
    {:ok, _ruled} = Pipeline.decide_finding(system_scope(), crash, :fix)

    assert {:error, :findings_undecided} = Pipeline.start_fix_round(run)
  end

  test "with findings ruled Fix it resumes the Review run on them, their rules and places, and the task stays at Review",
       %{task: task, run: %{id: run_id} = run, crash: crash, nit: nit} do
    {:ok, _ruled} = Pipeline.decide_finding(system_scope(), crash, :fix)
    {:ok, _ruled} = Pipeline.decide_finding(system_scope(), nit, :skip)

    expect(Tools, :start_os_process, fn %Run{id: ^run_id, stage_outcome: :in_progress} = spawned,
                                        ["-p", prompt | _rest] ->
      assert prompt =~ "Start fix round 1. The human ruled these 1 findings Fix"
      assert prompt =~ ~s(<finding key="nil-crash" severity="major" kind="code">)
      assert prompt =~ "Rule: Every caller handles nil."
      assert prompt =~ "1. lib/a.ex:3, handle/1\n2. lib/b.ex:9"
      refute prompt =~ "a-nit"

      {:ok, %OsProcess{run: %{spawned | status: :running}}}
    end)

    assert {:ok, %Run{id: ^run_id, status: :running}} = Pipeline.start_fix_round(run)
    assert %Task{stage: :review} = Repo.reload!(task)
    assert [_line | _rest] = run |> Pipeline.list_run_events() |> Enum.filter(&(&1.line =~ "[human] Start fix round 1"))
    assert Repo.exists?(from o in Observation, where: o.source_id == ^crash.id and o.source_kind == :review_finding)
  end

  test "a Fix finding carried into the round goes again, marked still failing", %{
    task: task,
    run: run,
    crash: crash,
    nit: nit
  } do
    {:ok, _ruled} = Pipeline.decide_finding(system_scope(), crash, :fix)
    {:ok, _ruled} = Pipeline.decide_finding(system_scope(), nit, :skip)
    {:ok, _fixed} = Pipeline.save_finding(task, %{key: "nil-crash", status: "fixed"})
    {:ok, %{round: 2}} = Pipeline.save_review(task)
    {:ok, %Finding{carried_round: 3}} = Pipeline.save_finding(task, %{key: "nil-crash", status: "not_fixed"})
    {:ok, %{round: 3}} = Pipeline.save_review(task)

    expect(Tools, :start_os_process, fn %Run{} = spawned, ["-p", prompt | _rest] ->
      assert prompt =~ "Start fix round 3."
      assert prompt =~ ~s(<finding key="nil-crash" severity="major" kind="code" still_failing="true">)
      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %Run{}} = Pipeline.start_fix_round(run)
  end

  test "with nothing ruled Fix the review finishes and the pull request leaves draft, once", %{
    task: task,
    run: run,
    crash: crash,
    nit: nit
  } do
    {:ok, _ruled} = Pipeline.decide_finding(system_scope(), crash, :skip)
    {:ok, _ruled} = Pipeline.decide_finding(system_scope(), nit, :skip)

    Req.Test.expect(Client, 3, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/app/installations/1/access_tokens"} -> Req.Test.json(conn, %{"token" => "ghs_token"})
        {"GET", "/repos/example/test-seed/pulls/9"} -> Req.Test.json(conn, %{"number" => 9, "node_id" => "PR_9"})
        {"POST", "/graphql"} -> Req.Test.json(conn, %{"data" => %{"markPullRequestReadyForReview" => %{}}})
      end
    end)

    assert {:ok, %Run{status: :finished}} = Pipeline.start_fix_round(run)
    assert %Task{pr_is_draft: false} = Repo.reload!(task)
    assert [%{finished_at: %DateTime{}}] = Pipeline.read_review(task)
    assert {:error, :nothing_to_start} = Pipeline.start_fix_round(run)
  end

  test "a second start while the round it started works is refused", %{task: task, run: run, crash: crash, nit: nit} do
    {:ok, _ruled} = Pipeline.decide_finding(system_scope(), crash, :fix)
    {:ok, _ruled} = Pipeline.decide_finding(system_scope(), nit, :fix)
    {:ok, _working} = Pipeline.update_run(run, %{status: :running})

    assert {:error, :stage_running} = Pipeline.start_fix_round(run)
    assert %Task{stage: :review} = Repo.reload!(task)
  end

  test "nothing starts before a round has finished, or on a task that left Review", %{task: task, run: run} do
    File.rm!(Path.join([task.scratch_path, "reviews", "SFR-1.json"]))
    assert {:error, :nothing_to_start} = Pipeline.start_fix_round(run)

    {:ok, _merged} = Pipeline.update_task(task, %{stage: :merged})
    assert {:error, {:invalid_stage, :merged}} = Pipeline.start_fix_round(run)
  end

  test "a lead that cannot be spawned keeps its failure on the run, and dispatch off says so", %{
    run: run,
    crash: crash,
    nit: nit
  } do
    {:ok, _ruled} = Pipeline.decide_finding(system_scope(), crash, :fix)
    {:ok, _ruled} = Pipeline.decide_finding(system_scope(), nit, :fix)

    expect(Tools, :start_os_process, fn %Run{} = spawned, _argv ->
      {:error, {:spawn_failed, :enoent, %{spawned | error: "Could not start"}}}
    end)

    assert {:ok, %Run{error: "Could not start"}} = Pipeline.start_fix_round(run)

    expect(Tools, :start_os_process, fn %Run{}, _argv -> {:error, :dispatch_disabled} end)
    assert {:error, :dispatch_disabled} = Pipeline.start_fix_round(run)
  end
end
