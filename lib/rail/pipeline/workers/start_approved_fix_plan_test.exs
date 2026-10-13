defmodule Rail.Pipeline.Workers.StartApprovedFixPlanTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.FixPlan
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Workers.StartApprovedFixPlan
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess
  alias Rail.Users

  @plan "Guard nil.\n\n### What changes\n\n#### `nil-crash`\n\nGuard it at the caller.\n\n" <>
          "### File-level changes\n\n- `lib/a.ex`: guards nil. For `nil-crash`."

  setup %{project: project} do
    {:ok, role} = Roles.get_role(project_id: project.id, stage: :review_lead)

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_safp_1", "identifier" => "SAFP-1", "title" => "Start Approved Fix Plan"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Start Approved Fix Plan"})
    {:ok, task} = Pipeline.create_task(issue, :review)
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: create_temp_git_repo()})
    task = Repo.preload(task, :issue)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :finished,
        stage_outcome: :done,
        conversation_id: "sess_safp",
        started_at: DateTime.utc_now()
      })

    {:ok, crash} =
      Pipeline.save_finding(task, %{
        key: "nil-crash",
        title: "Nil crashes the page",
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
        places: [%{file: "lib/a.ex", line: 3}],
        evidence: [%{name: "range", kind: :code, file: "lib/a.ex", line: 3}]
      })

    {:ok, %{round: 1}} = Pipeline.save_review(task)
    {:ok, _ruled} = Pipeline.decide_finding(system_scope(), crash, :fix)

    expect(Tools, :start_os_process, fn %Run{} = spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)
    {:ok, _started} = Pipeline.start_fix_round(system_scope(), run)
    {:ok, _saved} = Pipeline.save_fix_plan(task, %{"plan" => @plan})
    {:ok, run} = run |> Repo.reload!() |> Pipeline.update_run(%{status: :finished, stage_outcome: :done})

    {:ok, ada} =
      Users.register_oauth_user(%{
        github_id: "gh_safp_ada",
        login: "ada-start-approved-fix-plan",
        email: "ada-safp@example.com"
      })

    {:ok, %Run{status: :running}} =
      Pipeline.approve_fix_plan(user_scope(user: %{ada | project_ids: [project.id]}), run, 1)

    [%Oban.Job{args: args}] = all_enqueued(worker: StartApprovedFixPlan)

    # A spawn that writes its row, as the real one does before anything can fail.
    spawned = fn %Run{} = run, _argv ->
      process =
        Repo.insert!(%OsProcess{
          run_id: run.id,
          task_id: run.task_id,
          stream_path: "/tmp/safp.ndjson",
          status: :running,
          started_at: DateTime.utc_now()
        })

      {:ok, %{process | run: run}}
    end

    %{task: task, run: run, args: args, spawned: spawned}
  end

  test "resumes the lead on the approved plan word for word, records who approved it and says so once", %{
    task: %{id: task_id} = task,
    run: %{id: run_id} = run,
    args: args
  } do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline")
    # As an Approve that died between its commit and writing the approval leaves it.
    path = Path.join([task.scratch_path, "fix_plans", "SAFP-1.json"])
    unwritten = path |> File.read!() |> Jason.decode!() |> Map.merge(%{"approved_by" => nil, "approved_at" => nil})
    File.write!(path, Jason.encode!(unwritten))

    expect(Tools, :start_os_process, fn %Run{id: ^run_id, status: :running} = spawned, ["-p", prompt | _rest] ->
      # The approval is on disk before the turn can end, or its end would read as a planning turn's.
      assert %FixPlan{approved_by: "ada-start-approved-fix-plan"} = Pipeline.read_fix_plan(task)
      assert prompt =~ "<fix_plan>\n#{@plan}\n</fix_plan>"
      {:ok, %OsProcess{run: spawned}}
    end)

    assert :ok = perform_job(StartApprovedFixPlan, args)

    assert %FixPlan{approved_by: "ada-start-approved-fix-plan", approved_at: %DateTime{}, version: 1} =
             Pipeline.read_fix_plan(task)

    assert ["[human] ada-start-approved-fix-plan approved the fix plan."] =
             for(%{line: line} <- Pipeline.list_run_events(run), line =~ "approved", do: line)

    assert_received {:pipeline_changed, ^task_id}
  end

  test "an attempt that died after its spawn does not resume the lead twice", %{
    run: run,
    args: args,
    spawned: spawned
  } do
    expect(Tools, :start_os_process, spawned)
    queued_at = DateTime.shift(DateTime.utc_now(), second: -1)

    assert :ok = perform_job(StartApprovedFixPlan, args, inserted_at: queued_at)
    assert :ok = perform_job(StartApprovedFixPlan, args, inserted_at: queued_at, attempt: 2)

    assert [%OsProcess{}] = Tools.list_os_processes(run_id: run.id)
    assert [_once] = Enum.filter(Pipeline.list_run_events(run), &(&1.line =~ "approved the fix plan"))
  end

  test "a start that fails to spawn leaves the plan waiting and says nothing was approved", %{
    task: task,
    run: run,
    args: args
  } do
    expect(Tools, :start_os_process, fn %Run{} = spawned, _argv ->
      {:error, {:spawn_failed, :enoent, %{spawned | error: "Could not start"}}}
    end)

    assert :ok = perform_job(StartApprovedFixPlan, args)
    assert %FixPlan{approved_at: nil, approved_by: nil} = Pipeline.read_fix_plan(task)
    refute Enum.any?(Pipeline.list_run_events(run), &(&1.line =~ "approved the fix plan"))
  end

  test "a start with dispatch off leaves the plan waiting and the run as it was", %{
    task: task,
    run: run,
    args: args
  } do
    expect(Tools, :start_os_process, fn %Run{}, _argv -> {:error, :dispatch_disabled} end)

    assert :ok = perform_job(StartApprovedFixPlan, args)
    assert %FixPlan{approved_at: nil, approved_by: nil} = Pipeline.read_fix_plan(task)
    assert %Run{status: :finished, stage_outcome: :done, error: nil} = Repo.reload!(run)
    refute Enum.any?(Pipeline.list_run_events(run), &(&1.line =~ "approved the fix plan"))
  end

  test "a run stopped before the start leaves the plan waiting and starts nothing", %{
    task: task,
    run: run,
    args: args
  } do
    reject(Tools, :start_os_process, 2)
    {:ok, _stopped} = run |> Repo.reload!() |> Pipeline.update_run(%{status: :finished})

    assert :ok = perform_job(StartApprovedFixPlan, args)
    assert %FixPlan{approved_at: nil} = Pipeline.read_fix_plan(task)
  end

  test "a plan replaced since, or a run gone, needs nothing", %{task: task, args: args} do
    reject(Tools, :start_os_process, 2)
    path = Path.join([task.scratch_path, "fix_plans", "SAFP-1.json"])
    later = path |> File.read!() |> Jason.decode!() |> Map.merge(%{"version" => 2, "approved_at" => nil})
    File.write!(path, Jason.encode!(later))

    assert :ok = perform_job(StartApprovedFixPlan, args)
    assert %FixPlan{approved_at: nil, version: 2} = Pipeline.read_fix_plan(task)
    assert :ok = perform_job(StartApprovedFixPlan, %{args | "run_id" => "run_gone"})
  end
end
