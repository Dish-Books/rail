defmodule Rail.Pipeline.Actions.ApproveFixPlanTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.FixPlan
  alias Rail.Pipeline.Schemas.PlanComment
  alias Rail.Pipeline.Schemas.Round
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Pipeline.Workers.StartEngineer
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
    # The round the review read, built on the plan the lead approved.
    Repo.insert!(%Round{task_id: task.id, number: 1, plan: "Filter by vendor.", approved_at: DateTime.utc_now()})
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

    {:ok, %{id: ada_id} = ada} =
      Users.register_oauth_user(%{github_id: "gh_afp_ada", login: "ada-approve-fix-plan", email: "ada-afp@example.com"})

    %{
      task: task,
      run: run,
      crash: crash,
      nit: nit,
      ada: user_scope(user: %{ada | project_ids: [project.id]}),
      ada_id: ada_id
    }
  end

  test "approving the latest waiting plan makes it the next round and queues the engineer's start on it", %{
    task: %{id: task_id} = task,
    run: %{id: run_id} = run,
    ada: ada,
    ada_id: ada_id
  } do
    {:ok, _resaved} = Pipeline.save_fix_plan(task, %{"plan" => @plan, "retake_screens" => true})
    {:ok, _marked} = Pipeline.update_task(task, %{marked_ready_at: DateTime.utc_now()})
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline")
    # The start is the job's, committed with the round, so it survives the page that approved.
    reject(Tools, :start_os_process, 2)

    assert {:ok, %Run{id: ^run_id}} = Pipeline.approve_fix_plan(ada, run, 2)

    assert [
             %Round{number: 1},
             %Round{number: 2, plan: @plan, plan_version: 2, record_demo: false, retake_screens: true} = round
           ] =
             Pipeline.list_rounds(task)

    assert %Round{approved_at: %DateTime{}, approved_by_id: ^ada_id} = round
    # Changes are coming, so a task a teammate marked ready is not ready any more.
    assert %Task{stage: :engineer, marked_ready_at: nil} = Repo.reload!(task)
    assert %FixPlan{approved_by: "ada-approve-fix-plan", approved_at: %DateTime{}} = Pipeline.read_fix_plan(task)
    assert_enqueued(worker: StartEngineer, args: %{task_id: task_id})
    assert_received {:pipeline_changed, ^task_id}
  end

  # Every agent after reads the criteria as they now stand, and the tracker's ticket keeps its design.
  test "a plan that changes the ticket puts it on the new round and the issue once approved", %{
    task: task,
    run: run,
    ada: ada
  } do
    {:ok, _designed} =
      Issues.update_issue(task.issue, %{description: "Filter by vendor.\n\n## Design: Chips\n\nChips."})

    amended = "### Changes to the plan\n\n- Criteria: vendor becomes tag, as Ada asked.\n\n" <> @plan

    {:ok, _saved} =
      Pipeline.save_fix_plan(task, %{"plan" => amended, "title" => "Filter by tag", "description" => "Filter by tag."})

    reject(Tools, :start_os_process, 2)
    assert {:ok, %Run{}} = Pipeline.approve_fix_plan(ada, run, 2)

    assert %Round{number: 2, ticket: %Round.Ticket{title: "Filter by tag", description: "Filter by tag."}} =
             Pipeline.read_plan(task)

    assert %{title: "Filter by tag", description: "Filter by tag.\n\n## Design: Chips\n\nChips."} =
             Repo.reload!(task.issue)
  end

  test "a ticket with no design section takes the new description as it is", %{task: task, run: run, ada: ada} do
    amended = "### Changes to the plan\n\n- Criteria: vendor becomes tag, as Ada asked.\n\n" <> @plan
    {:ok, _saved} = Pipeline.save_fix_plan(task, %{"plan" => amended, "description" => "Filter by tag."})
    reject(Tools, :start_os_process, 2)

    assert {:ok, %Run{}} = Pipeline.approve_fix_plan(ada, run, 2)
    assert %{description: "Filter by tag."} = Repo.reload!(task.issue)
  end

  # The ticket's picture is the design as approved, so a plan that changed it puts the new one up.
  test "a plan that changed the design puts its new picture on the issue once approved", %{task: task, run: run, ada: ada} do
    dir = Path.join(task.scratch_path, "design")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "chips.png"), "png bytes")
    File.write!(Path.join(dir, "chips.html"), "<h1>Chips</h1>")

    File.write!(
      Path.join(dir, "manifest.json"),
      Jason.encode!(%{options: [%{key: "chips", title: "Chips", summary: "As a menu now."}]})
    )

    File.write!(Path.join(dir, "picked"), "chips")

    {:ok, _old} =
      Issues.update_issue(task.issue, %{
        description: "Filter by vendor.\n\n## Design: Chips\n\nChips.\n\n![Chips](old.png)"
      })

    amended = "### Changes to the plan\n\n- Design: chips become a menu, as Ada asked.\n\n" <> @plan
    {:ok, _saved} = Pipeline.save_fix_plan(task, %{"plan" => amended, "design_changed" => true})
    expect(Issues, :upload_asset, fn _project, "AFP-1-chips.png", "image/png", "png bytes" -> {:ok, "new.png"} end)
    reject(Tools, :start_os_process, 2)

    assert {:ok, %Run{}} = Pipeline.approve_fix_plan(ada, run, 2)

    assert %{description: "Filter by vendor.\n\n## Design: Chips\n\nAs a menu now.\n\n![Chips](new.png)"} =
             Repo.reload!(task.issue)
  end

  test "a tracker that cannot hold the picture gets the design's text", %{task: task, run: run, ada: ada} do
    dir = Path.join(task.scratch_path, "design")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "chips.png"), "png bytes")
    File.write!(Path.join(dir, "chips.html"), "<h1>Chips</h1>")

    File.write!(
      Path.join(dir, "manifest.json"),
      Jason.encode!(%{options: [%{key: "chips", title: "Chips", summary: "A menu."}]})
    )

    File.write!(Path.join(dir, "picked"), "chips")
    {:ok, _old} = Issues.update_issue(task.issue, %{description: "Filter."})

    amended = "### Changes to the plan\n\n- Design: a menu, as Ada asked.\n\n" <> @plan
    {:ok, _saved} = Pipeline.save_fix_plan(task, %{"plan" => amended, "design_changed" => true})
    expect(Issues, :upload_asset, fn _project, _name, _type, _bytes -> {:error, :unsupported} end)
    reject(Tools, :start_os_process, 2)

    assert {:ok, %Run{}} = Pipeline.approve_fix_plan(ada, run, 2)
    assert %{description: "Filter.\n\n## Design: Chips\n\nA menu."} = Repo.reload!(task.issue)
  end

  test "a design changed with nothing picked puts no design section up", %{task: task, run: run, ada: ada} do
    {:ok, _old} = Issues.update_issue(task.issue, %{description: "Filter."})
    amended = "### Changes to the plan\n\n- Design: a menu, as Ada asked.\n\n" <> @plan
    {:ok, _saved} = Pipeline.save_fix_plan(task, %{"plan" => amended, "design_changed" => true})
    reject(&Issues.upload_asset/4)
    reject(Tools, :start_os_process, 2)

    assert {:ok, %Run{}} = Pipeline.approve_fix_plan(ada, run, 2)
    assert %{description: "Filter."} = Repo.reload!(task.issue)
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
    assert {:ok, %Run{}} = Pipeline.approve_fix_plan(ada, run, 1)
  end

  test "two Approves of the latest plan at once make one round and queue the engineer's start once", %{
    task: task,
    run: run,
    ada: ada
  } do
    results =
      Elixir.Task.await_many(for _tab <- 1..2, do: Elixir.Task.async(fn -> Pipeline.approve_fix_plan(ada, run, 1) end))

    assert [{:error, {:fix_plan_not_waiting, :approved}}, {:ok, %Run{}}] = Enum.sort(results)
    assert [%Round{number: 1}, %Round{number: 2}] = Pipeline.list_rounds(task)
    assert [%Oban.Job{}] = all_enqueued(worker: StartEngineer)
  end

  test "an Approve while the review agent works, or with no plan saved, is refused", %{task: task, run: run, ada: ada} do
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

  # A comment left unsent on the plan asked for a change approving it passed over; one already sent is history.
  test "approving drops every reader's unsent comments on the plan, keeps the sent and the other documents' and tells their authors",
       %{task: %{id: task_id} = task, run: run, ada: ada, ada_id: ada_id} do
    {:ok, %{id: grace_id}} =
      Users.register_oauth_user(%{
        github_id: "gh_afp_grace",
        login: "grace-approve-fix-plan",
        email: "grace-afp@example.com"
      })

    line = %PlanComment{
      task_id: task_id,
      element_kind: :paragraph,
      element_label: "Fix finding nil-crash, paragraph 1",
      element_occurrence: 1,
      element_text: "Guard it at the caller.",
      body: "Hm."
    }

    Repo.insert!(%{line | user_id: ada_id, target: :fix_plan, body: "Ada's unsent."})
    Repo.insert!(%{line | user_id: grace_id, target: :fix_plan, body: "Grace's unsent."})
    %{id: sent_id} = Repo.insert!(%{line | user_id: ada_id, target: :fix_plan, status: :sent, body: "Sent."})
    %{id: queued_id} = Repo.insert!(%{line | user_id: grace_id, target: :fix_plan, status: :queued, body: "Queued."})
    %{id: plan_id} = Repo.insert!(%{line | user_id: ada_id, target: :plan, body: "On the first plan."})

    Phoenix.PubSub.subscribe(Rail.PubSub, "plan_comments:#{task_id}:#{ada_id}")
    Phoenix.PubSub.subscribe(Rail.PubSub, "plan_comments:#{task_id}:#{grace_id}")
    reject(Tools, :start_os_process, 2)

    assert {:ok, %Run{}} = Pipeline.approve_fix_plan(ada, run, 1)

    assert [^plan_id, ^queued_id, ^sent_id] =
             Repo.all(from c in PlanComment, where: c.task_id == ^task_id, order_by: c.body, select: c.id)

    assert_received {:plan_comments_changed, ^task_id}
    assert_received {:plan_comments_changed, ^task_id}
    refute_received {:plan_comments_changed, ^task_id}
    assert %FixPlan{approved_at: %DateTime{}} = Pipeline.read_fix_plan(task)
  end

  test "a refused Approve leaves the unsent comments on the plan", %{
    task: %{id: task_id},
    run: run,
    ada: ada,
    ada_id: ada_id
  } do
    Repo.insert!(%PlanComment{
      task_id: task_id,
      user_id: ada_id,
      target: :fix_plan,
      element_kind: :file,
      element_label: "File 1",
      element_occurrence: 1,
      element_text: "lib/a.ex",
      body: "Not this file."
    })

    reject(Tools, :start_os_process, 2)

    assert {:error, {:fix_plan_replaced, _saved_at}} = Pipeline.approve_fix_plan(ada, run, 0)

    assert [%PlanComment{status: :unsent, body: "Not this file."}] =
             Repo.all(from c in PlanComment, where: c.task_id == ^task_id)
  end

  test "a scope outside the task's project reads it as not found", %{run: run} do
    assert {:error, :not_found} = Pipeline.approve_fix_plan(user_scope(), run, 1)
  end
end
