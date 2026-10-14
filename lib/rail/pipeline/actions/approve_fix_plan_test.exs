defmodule Rail.Pipeline.Actions.ApproveFixPlanTest do
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
            "issue" => %{"id" => "lin_afp_1", "identifier" => "AFP-1", "title" => "Approve Fix Plan"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Approve Fix Plan"})
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
        conversation_id: "sess_afp",
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
      places: [%{file: "lib/a.ex", line: 3}],
      evidence: [%{name: "range", kind: :code, file: "lib/a.ex", line: 3}]
    }

    {:ok, crash} = Pipeline.save_finding(task, Map.merge(attrs, %{key: "nil-crash", title: "Nil crashes the page"}))
    {:ok, nit} = Pipeline.save_finding(task, Map.merge(attrs, %{key: "a-nit", title: "A nit", severity: :nit}))
    {:ok, %{round: 1}} = Pipeline.save_review(task)
    {:ok, _ruled} = Pipeline.decide_finding(system_scope(), crash, :fix)
    {:ok, _ruled} = Pipeline.decide_finding(system_scope(), nit, :skip)

    expect(Tools, :start_os_process, fn %Run{} = spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)
    {:ok, _started} = Pipeline.start_fix_round(system_scope(), run)
    {:ok, _saved} = Pipeline.save_fix_plan(task, %{"plan" => @plan})
    {:ok, run} = run |> Repo.reload!() |> Pipeline.update_run(%{status: :finished, stage_outcome: :done})

    {:ok, ada} =
      Users.register_oauth_user(%{github_id: "gh_afp_ada", login: "ada-approve-fix-plan", email: "ada-afp@example.com"})

    %{task: task, run: run, crash: crash, nit: nit, ada: user_scope(user: %{ada | project_ids: [project.id]})}
  end

  test "approving the latest waiting plan claims the run on it word for word and queues the lead's start", %{
    task: %{id: task_id} = task,
    run: %{id: run_id} = run,
    ada: ada
  } do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline")
    # The start is the job's, committed with the claim, so it survives the page that approved.
    reject(Tools, :start_os_process, 2)

    assert {:ok, %Run{id: ^run_id, status: :running, pending_answer: note}} = Pipeline.approve_fix_plan(ada, run, 1)
    assert note =~ "<fix_plan>\n#{@plan}\n</fix_plan>"
    assert %Run{status: :running} = Repo.reload!(run)
    # Read approved before the job runs, so no page shows the claimed run as revising the plan.
    assert %FixPlan{approved_by: "ada-approve-fix-plan", approved_at: %DateTime{}, version: 1} =
             Pipeline.read_fix_plan(task)

    assert_enqueued(
      worker: StartApprovedFixPlan,
      args: %{run_id: run_id, version: 1, approved_by: "ada-approve-fix-plan"}
    )

    refute Enum.any?(Pipeline.list_run_events(run), &(&1.line =~ "approved the fix plan"))
    assert_received {:pipeline_changed, ^task_id}
  end

  test "a replaced version, or a plan revising, is refused and nothing starts", %{
    task: task,
    run: run,
    ada: ada
  } do
    {:ok, %FixPlan{saved_at: saved_at}} = Pipeline.save_fix_plan(task, %{"plan" => @plan <> " Again."})
    reject(Tools, :start_os_process, 2)

    assert {:error, {:fix_plan_replaced, ^saved_at}} = Pipeline.approve_fix_plan(ada, run, 1)

    # A Send of a comment leaves the saved plan covering less than what was sent.
    path = Path.join([task.scratch_path, "fix_plans", "AFP-1.json"])
    fix_plan = path |> File.read!() |> Jason.decode!()
    File.write!(path, Jason.encode!(%{fix_plan | "comments" => [%{number: 1, kind: "diff", text: "Why?"}]}))

    assert {:error, {:fix_plan_not_waiting, :revising}} = Pipeline.approve_fix_plan(ada, run, 2)
    assert %FixPlan{approved_at: nil} = Pipeline.read_fix_plan(task)
    assert %Run{status: :finished} = Repo.reload!(run)
  end

  test "a plan whose rulings changed after it was saved is refused, and approved once they are changed back", %{
    run: run,
    crash: crash,
    ada: ada
  } do
    {:ok, _ruled} = Pipeline.decide_finding(system_scope(), crash, :skip)
    assert {:error, {:fix_plan_not_waiting, :outdated}} = Pipeline.approve_fix_plan(ada, run, 1)
    assert %Run{status: :finished} = Repo.reload!(run)

    {:ok, _ruled} = Pipeline.decide_finding(system_scope(), crash, :fix)
    assert {:ok, %Run{status: :running}} = Pipeline.approve_fix_plan(ada, run, 1)
  end

  test "two Approves of the latest plan at once queue the lead's start once", %{run: run, ada: ada} do
    results =
      Task.await_many(for _tab <- 1..2, do: Task.async(fn -> Pipeline.approve_fix_plan(ada, run, 1) end))

    assert [{:error, :stage_running}, {:ok, %Run{}}] = Enum.sort(results)
    assert [%Oban.Job{}] = all_enqueued(worker: StartApprovedFixPlan)
  end

  test "an Approve while a start for the run is still queued claims nothing", %{run: %{id: run_id} = run, ada: ada} do
    {:ok, _queued} = Oban.insert(StartApprovedFixPlan.new(%{run_id: run_id, version: 1}))

    assert {:error, :stage_running} = Pipeline.approve_fix_plan(ada, run, 1)
    assert %Run{status: :finished, stage_outcome: :done, pending_answer: "Sent 1 finding." <> _send} = Repo.reload!(run)
  end

  test "an Approve while the lead works, or with no plan saved, is refused", %{task: task, run: run, ada: ada} do
    reject(Tools, :start_os_process, 2)
    {:ok, working} = Pipeline.update_run(run, %{status: :running})
    assert {:error, :stage_running} = Pipeline.approve_fix_plan(ada, working, 1)

    {:ok, idle} = Pipeline.update_run(working, %{status: :finished})
    path = Path.join([task.scratch_path, "fix_plans", "AFP-1.json"])
    fix_plan = path |> File.read!() |> Jason.decode!()
    File.write!(path, Jason.encode!(%{fix_plan | "plan" => nil, "version" => 0}))

    assert {:error, {:fix_plan_not_waiting, :writing}} = Pipeline.approve_fix_plan(ada, idle, 0)

    File.rm!(path)
    assert {:error, :no_fix_plan} = Pipeline.approve_fix_plan(ada, idle, 0)
  end

  test "a scope outside the task's project reads it as not found", %{run: run} do
    assert {:error, :not_found} = Pipeline.approve_fix_plan(user_scope(), run, 1)
  end
end
