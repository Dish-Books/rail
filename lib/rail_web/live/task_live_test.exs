defmodule RailWeb.TaskLiveTest do
  use RailWeb.ConnCase, async: true

  import Ecto.Query
  import Mimic
  import Phoenix.LiveViewTest
  import RailWeb.Utils.BuildDocumentBlocks

  alias Phoenix.Socket.Message
  alias Rail.Git
  alias Rail.GitHub.Client
  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.DetectedQuestion
  alias Rail.Pipeline.Schemas.Finding
  alias Rail.Pipeline.Schemas.ImplementationPlan
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Scope
  alias Rail.Tools
  alias Rail.Tools.Schemas.Backend
  alias Rail.Tools.Schemas.BrowserSession
  alias Rail.Tools.Schemas.OsProcess
  alias Rail.Users

  # The smallest plan the structure allows: no diagrams, so Approach says why, and no Program design.
  @plan """
  ## Implementation plan

  ### Approach

  Extend the module.

  No diagrams: one module changes.

  ### File-level changes

  - `lib/rail.ex`: extends the module.

  ### Verification

  - `lib/rail_test.exs`: covers the extension.
  """

  setup %{conn: conn, project: project} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_task_live",
        login: "task_live_user",
        email: "task_live_user@example.com",
        admin: true
      })

    scope = Scope.for_user(user)

    {:ok, backend} = Tools.create_backend(system_scope(), %{name: :claude, executable_path: "/usr/bin/true"})

    {:ok, role} = Roles.get_role(project_id: project.id, stage: :plan)

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{
              "id" => "lin_task_live_1",
              "identifier" => "TLV-1",
              "title" => "Task Live Issue"
            }
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Task Live Issue"})
    {:ok, task} = Pipeline.create_task(issue, :plan)
    File.mkdir_p!(Path.join(task.scratch_path, "tickets"))
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :finished,
        stage_outcome: :done,
        started_at: DateTime.utc_now()
      })

    %{
      conn: log_in_user(conn, user),
      scope: scope,
      backend: backend,
      project: project,
      issue: issue,
      task: task,
      role: role,
      run: run
    }
  end

  test "the header names the issue, its branch and what the run is doing", %{conn: conn, task: task} do
    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    assert has_element?(view, "[data-qa='task_detail_title']", "Task Live Issue")
    assert has_element?(view, "[data-qa='task_issue_identifier']", "TLV-1")
    assert has_element?(view, "[data-qa='task_branch_name']", task.worktree_name)
    assert has_element?(view, "[data-qa='task_status_chip']", "Review the plan")
  end

  test "the header reads the task's own stage, not the tab a stage with no run falls back to", %{
    conn: conn,
    task: task,
    project: project
  } do
    {:ok, engineer} = Roles.get_role(project_id: project.id, stage: :engineer)
    {:ok, task} = Pipeline.update_task(task, %{stage: :review, worktree_path: create_temp_git_repo()})

    {:ok, _engineer_run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: engineer.id,
        status: :finished,
        stage_outcome: :done,
        started_at: DateTime.utc_now()
      })

    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    assert has_element?(view, "[data-qa='task_status_chip']", "Queued for Review")
  end

  test "a stage waiting for resources says so, and where it stands in line", %{
    conn: conn,
    task: task,
    project: project
  } do
    {:ok, engineer} = Roles.get_role(project_id: project.id, stage: :engineer)
    {:ok, engineer} = Roles.update_role(system_scope(), engineer, %{reserved_cpus: 2, reserved_memory_gb: 4})
    {:ok, task} = Pipeline.update_task(task, %{stage: :engineer, worktree_path: create_temp_git_repo()})
    now = DateTime.utc_now()

    {:ok, run} =
      Pipeline.create_run(%{task_id: task.id, role_id: engineer.id, status: :waiting_for_resources, started_at: now})

    Repo.insert!(%OsProcess{
      run_id: run.id,
      task_id: task.id,
      stream_path: "/dev/null",
      status: :waiting_for_resources,
      started_at: now,
      queued_at: now,
      reserved_cpus: 2,
      reserved_memory_gb: 4
    })

    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    assert has_element?(view, "[data-qa='task_status_chip']", "Engineer waiting for resources")
    assert has_element?(view, "#task-line[href='/sandboxes']", "1st in line for 2 CPUs · 4 GB")
    assert has_element?(view, "#task-tab-#{engineer.id}", "waiting for resources")
    assert has_element?(view, "#task-tab-#{engineer.id} [data-qa='task-tab-dot'][data-tone='waiting']")
  end

  test "a stage waiting for usage says when it starts, reads apart from a sandbox wait, and starts on its own", %{
    conn: conn,
    task: task,
    project: project
  } do
    model = "claude-task-usage-#{System.unique_integer([:positive])}"
    {:ok, engineer} = Roles.get_role(project_id: project.id, stage: :engineer)
    {:ok, engineer} = Roles.update_role(system_scope(), engineer, %{model: model})
    {:ok, task} = Pipeline.update_task(task, %{stage: :engineer, worktree_path: create_temp_git_repo()})
    reset = DateTime.utc_now() |> DateTime.shift(hour: 2) |> DateTime.truncate(:second)

    {:ok, account} =
      Tools.create_backend(system_scope(), %{
        name: :claude,
        label: "work",
        executable_path: "/usr/bin/true",
        models: [%{id: model}]
      })

    # Its 5-hour window is spent until `reset`.
    session = %{"label" => "Session", "remaining_percent" => 0.0, "resets_at" => DateTime.to_iso8601(reset)}

    account =
      account
      |> Backend.usage_changeset(%{
        name: :claude,
        status: :ready,
        usage: [%{name: "Session", details: %{"windows" => [session]}}]
      })
      |> Repo.update!()

    {:ok, run} =
      Pipeline.create_run(%{task_id: task.id, role_id: engineer.id, status: :starting, started_at: DateTime.utc_now()})

    assert {:ok, %OsProcess{id: waiting_id, status: :waiting_for_usage}} = Tools.start_os_process(run, ["2"])

    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}?tab=#{engineer.id}")

    assert has_element?(view, "[data-qa='task_status_chip']", "Engineer waiting for usage")
    assert has_element?(view, "#task-usage-starts", "· starts")
    assert has_element?(view, "#task-usage-starts-at[data-at='#{DateTime.to_iso8601(reset)}']")
    refute has_element?(view, "#task-line")
    assert has_element?(view, "#task-tab-#{engineer.id}", "waiting for usage")
    assert has_element?(view, "#task-tab-#{engineer.id} [data-qa='task-tab-dot'][data-tone='waiting_for_usage']")
    assert has_element?(view, "#usage-banner", "is waiting for usage")

    # The reset passes, and the job starts the turn with nobody on the page doing anything.
    account
    |> Backend.usage_changeset(%{name: :claude, status: :ready, usage: []})
    |> Repo.update!()

    stub(Tools, :spawn_os_process, fn _executable, _args, _opts -> {:ok, nil, 4270} end)
    stub(Rail.Tools.FollowerSupervisor, :start_follower, fn _os_process, _opts -> {:ok, self()} end)
    assert {:ok, %OsProcess{status: :running}} = Tools.start_after_usage_reset(waiting_id)

    eventually(fn ->
      assert has_element?(view, "[data-qa='task_status_chip']", "Engineer running")
      refute has_element?(view, "#usage-banner")
    end)
  end

  test "stopping a stage waiting for usage clears its header and tab without a reload", %{
    conn: conn,
    task: task,
    project: project
  } do
    model = "claude-task-usage-stop-#{System.unique_integer([:positive])}"
    {:ok, engineer} = Roles.get_role(project_id: project.id, stage: :engineer)
    {:ok, engineer} = Roles.update_role(system_scope(), engineer, %{model: model})
    {:ok, task} = Pipeline.update_task(task, %{stage: :engineer, worktree_path: create_temp_git_repo()})
    reset = DateTime.utc_now() |> DateTime.shift(hour: 2) |> DateTime.truncate(:second)

    {:ok, account} =
      Tools.create_backend(system_scope(), %{name: :claude, executable_path: "/usr/bin/true", models: [%{id: model}]})

    session = %{"label" => "Session", "remaining_percent" => 0.0, "resets_at" => DateTime.to_iso8601(reset)}

    account
    |> Backend.usage_changeset(%{
      name: :claude,
      status: :ready,
      usage: [%{name: "Session", details: %{"windows" => [session]}}]
    })
    |> Repo.update!()

    {:ok, run} =
      Pipeline.create_run(%{task_id: task.id, role_id: engineer.id, status: :starting, started_at: DateTime.utc_now()})

    assert {:ok, %OsProcess{status: :waiting_for_usage}} = Tools.start_os_process(run, ["2"])

    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}?tab=#{engineer.id}")
    assert has_element?(view, "[data-qa='task_status_chip']", "Engineer waiting for usage")

    view |> element("#usage-banner [data-qa='stop-run']") |> render_click()

    refute has_element?(view, "[data-qa='task_status_chip']", "waiting for usage")
    refute has_element?(view, "#task-usage-starts")
    refute has_element?(view, "#task-tab-#{engineer.id}", "waiting for usage")
  end

  test "a stage whose turn has just stopped waiting for usage names no start time", %{
    conn: conn,
    task: task,
    project: project
  } do
    {:ok, engineer} = Roles.get_role(project_id: project.id, stage: :engineer)
    {:ok, task} = Pipeline.update_task(task, %{stage: :engineer, worktree_path: create_temp_git_repo()})

    {:ok, _run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: engineer.id,
        status: :waiting_for_usage,
        started_at: DateTime.utc_now()
      })

    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    assert has_element?(view, "[data-qa='task_status_chip']", "Engineer waiting for usage")
    refute has_element?(view, "#task-usage-starts")
  end

  test "a resumed conversation waiting on its own account can be stopped from its card, and never starts", %{
    conn: conn,
    task: task,
    project: project
  } do
    model = "claude-task-pinned-#{System.unique_integer([:positive])}"
    {:ok, engineer} = Roles.get_role(project_id: project.id, stage: :engineer)
    {:ok, engineer} = Roles.update_role(system_scope(), engineer, %{model: model})
    {:ok, task} = Pipeline.update_task(task, %{stage: :engineer, worktree_path: create_temp_git_repo()})

    {:ok, work} =
      Tools.create_backend(system_scope(), %{
        name: :claude,
        label: "work",
        executable_path: "/usr/bin/true",
        models: [%{id: model}]
      })

    weekly = %{
      "label" => "Weekly",
      "remaining_percent" => 0.0,
      "resets_at" => DateTime.to_iso8601(DateTime.shift(DateTime.utc_now(), day: 1))
    }

    work
    |> Backend.usage_changeset(%{
      name: :claude,
      status: :ready,
      usage: [%{name: "Weekly", details: %{"windows" => [weekly]}}]
    })
    |> Repo.update!()

    now = DateTime.utc_now()

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: engineer.id,
        status: :waiting_for_usage,
        conversation_id: "conv_pinned",
        started_at: now
      })

    waiting =
      Repo.insert!(%OsProcess{
        run_id: run.id,
        task_id: task.id,
        backend_id: work.id,
        stream_path: "/dev/null",
        status: :waiting_for_usage,
        started_at: now,
        queued_at: now,
        launch: Jason.encode!(%{"argv" => ["2"], "token" => "tok"})
      })

    Pipeline.append_run_events(run.id, waiting.id, ["[rail] This conversation lives on Claude Code · work."])

    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}?tab=#{engineer.id}")
    assert has_element?(view, "#usage-wait-card", "This conversation lives on the work account")

    view |> element("#usage-wait-stop") |> render_click()

    assert %OsProcess{status: :finished, ended_reason: :stopped} = Repo.get!(OsProcess, waiting.id)
    assert %Run{status: :finished} = Repo.get!(Run, run.id)
    refute has_element?(view, "#usage-wait-card")
    assert {:error, :not_waiting} = Tools.start_after_usage_reset(waiting.id)
  end

  test "the header of a merged task says it merged", %{conn: conn, task: task} do
    {:ok, task} = Pipeline.update_task(task, %{stage: :merged, merged_at: DateTime.utc_now()})

    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    assert has_element?(view, "[data-qa='task_status_chip']", "Merged")
    refute has_element?(view, "[data-qa='task_status_chip']", "Queued")
  end

  test "an unassigned issue is claimed from the task page", %{conn: conn, task: task, scope: scope} do
    scope.user |> Ecto.Changeset.change(linear_user_id: "lin_usr_task_live") |> Repo.update!()

    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    view |> element("#claim-task") |> render_click()

    refute has_element?(view, "#claim-task")
    assert Repo.get!(Issue, task.issue_id).owner_user_id == scope.user.id
  end

  test "claiming an issue somebody claimed since the page loaded says so", %{
    conn: conn,
    task: task,
    scope: scope,
    issue: issue
  } do
    scope.user |> Ecto.Changeset.change(linear_user_id: "lin_usr_task_live") |> Repo.update!()

    {:ok, rival} =
      Users.register_oauth_user(%{github_id: "gh_task_rival", login: "task_rival", email: "task_rival@example.com"})

    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
    {:ok, _claimed} = Issues.update_issue(issue, %{owner_user_id: rival.id})

    view |> element("#claim-task") |> render_click()

    assert has_element?(view, "#flash-error", "Somebody else claimed this issue first")
    refute has_element?(view, "#claim-task")
  end

  test "claiming without a linked Linear account says what to do", %{conn: conn, task: task} do
    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    view |> element("#claim-task") |> render_click()

    assert has_element?(view, "#flash-error", "Link your Linear account in Settings before claiming an issue")
    assert has_element?(view, "#claim-task")
  end

  test "a run that recorded an error shows it", %{conn: conn, task: task, run: run} do
    {:ok, _failed} = Pipeline.update_run(run, %{error: "The agent gave up."})

    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    assert has_element?(view, "[data-qa='task_error_card']", "The agent gave up.")
  end

  test "the page hosts the conversation for the role on the tab", %{conn: conn, task: task, role: role} do
    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    assert has_element?(view, "[data-qa='conversation-tab']")
    assert has_element?(view, "#conversation-role-#{role.id}")
  end

  test "a run with no conversation refuses a message", %{conn: conn, task: task, run: run} do
    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    view |> element("#chat-composer-form") |> render_submit(%{"message" => "Hello?"})

    assert %Run{pending_chat: nil} = Repo.reload!(run)
  end

  test "a run that failed before starting a conversation is retried by entering its stage again", %{
    conn: conn,
    task: task,
    project: project
  } do
    {:ok, engineer} = Roles.get_role(project_id: project.id, stage: :engineer)

    {:ok, task} = Pipeline.update_task(task, %{stage: :engineer})

    {:ok, failed} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: engineer.id,
        status: :finished,
        error: "claude reported ERROR: Eligibility check failed",
        started_at: DateTime.utc_now()
      })

    stub(Git, :get_or_create_worktree, fn _project, _task -> {:ok, task.worktree_path} end)

    expect(Tools, :start_os_process, fn spawned, ["-p", prompt | _rest] ->
      assert prompt =~ "Build the approved plan below."
      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}?tab=#{engineer.id}")

    view |> element("#retry-run") |> render_click()

    assert %Run{status: :running, error: nil} = Repo.reload!(failed)
    refute has_element?(view, "#retry-run")
  end

  # The migration leaves every task it moved to Review on a stopped lead run with no conversation.
  test "a Review lead run with no conversation is retried by entering Review again", %{
    conn: conn,
    task: task,
    project: project
  } do
    {:ok, lead} = Roles.get_role(project_id: project.id, stage: :review_lead)
    {:ok, task} = Pipeline.update_task(task, %{stage: :review})

    {:ok, stopped} =
      Pipeline.create_run(%{task_id: task.id, role_id: lead.id, status: :finished, started_at: DateTime.utc_now()})

    stub(Git, :get_or_create_worktree, fn _project, _task -> {:ok, task.worktree_path} end)

    expect(Tools, :start_os_process, fn spawned, argv ->
      assert "--agents" in argv
      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}?tab=#{lead.id}")

    view |> element("#retry-run") |> render_click()

    assert %Run{status: :running, error: nil} = Repo.reload!(stopped)
    assert %Task{stage: :review} = Repo.reload!(task)
  end

  test "a question's options, tabs and draft all feed the answer", %{conn: conn, task: task, run: run} do
    {:ok, blocked} = Pipeline.update_run(run, %{status: :blocked_on_input, stage_outcome: :in_progress})
    blocked = Repo.preload(blocked, task: :issue)

    {:ok, _first} =
      Pipeline.register_question(blocked, %DetectedQuestion{prompt: "Which database?", options: ["Postgres", "MySQL"]})

    {:ok, _second} = Pipeline.register_question(blocked, %DetectedQuestion{prompt: "Which region?"})

    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    view |> element("#question-option-1") |> render_click()
    assert has_element?(view, "#answer-textarea", "MySQL")

    view |> form("#answer-question-form", %{"answer" => "Half typed"}) |> render_change()
    assert has_element?(view, "#answer-textarea", "Half typed")

    view |> element("#question-tab-1") |> render_click()
    assert has_element?(view, "#question-prompt", "Which region?")
  end

  test "working in the question card does not read the ticket again", %{conn: conn, task: task, run: run} do
    {:ok, blocked} = Pipeline.update_run(run, %{status: :blocked_on_input, stage_outcome: :in_progress})
    blocked = Repo.preload(blocked, task: :issue)

    {:ok, _first} =
      Pipeline.register_question(blocked, %DetectedQuestion{prompt: "Which database?", options: ["Postgres", "MySQL"]})

    {:ok, _second} = Pipeline.register_question(blocked, %DetectedQuestion{prompt: "Which region?"})

    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
    reject(&Pipeline.read_ticket/1)

    for typed <- ["P", "Po", "Postgres", "Postgres, on the managed plan"] do
      view |> form("#answer-question-form", %{"answer" => typed}) |> render_change()
      assert has_element?(view, "#answer-textarea", typed)
    end

    view |> element("#question-option-1") |> render_click()
    assert has_element?(view, "#question-option-1.bg-blue-100")

    view |> element("#question-tab-1") |> render_click()
    assert has_element?(view, "#question-prompt", "Which region?")
  end

  test "an answer saved straight after typing is the text submitted, to its last character", %{
    conn: conn,
    task: task,
    run: run
  } do
    {:ok, blocked} = Pipeline.update_run(run, %{status: :blocked_on_input, stage_outcome: :in_progress})
    blocked = Repo.preload(blocked, task: :issue)

    {:ok, question} = Pipeline.register_question(blocked, %DetectedQuestion{prompt: "Which database?"})

    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    view |> form("#answer-question-form", %{"answer" => "Post"}) |> render_change()
    view |> form("#answer-question-form", %{"answer" => "Postgres 1"}) |> render_change()
    view |> form("#answer-question-form", %{"answer" => "Postgres 16"}) |> render_submit()

    assert {:ok, %{status: :answered, answer: "Postgres 16"}} = Pipeline.get_question(question.id)
  end

  test "a picked chip stays in step with the text under it", %{conn: conn, task: task, run: run} do
    {:ok, blocked} = Pipeline.update_run(run, %{status: :blocked_on_input, stage_outcome: :in_progress})
    blocked = Repo.preload(blocked, task: :issue)

    {:ok, _question} =
      Pipeline.register_question(blocked, %DetectedQuestion{prompt: "Which database?", options: ["Postgres", "MySQL"]})

    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    view |> element("#question-option-0") |> render_click()
    assert has_element?(view, "#question-option-0.bg-blue-100")
    refute has_element?(view, "#question-option-1.bg-blue-100")

    view |> form("#answer-question-form", %{"answer" => "Postgres, but"}) |> render_change()
    refute has_element?(view, "#question-option-0.bg-blue-100")

    view |> form("#answer-question-form", %{"answer" => "Postgres"}) |> render_change()
    assert has_element?(view, "#question-option-0.bg-blue-100")
  end

  test "a blocked run's questions are answered here and sent as one round", %{
    conn: conn,
    task: task,
    run: run
  } do
    {:ok, blocked} = Pipeline.update_run(run, %{status: :blocked_on_input, stage_outcome: :in_progress})
    blocked = Repo.preload(blocked, task: :issue)

    {:ok, _first} = Pipeline.register_question(blocked, %DetectedQuestion{prompt: "Which database?"})
    {:ok, _second} = Pipeline.register_question(blocked, %DetectedQuestion{prompt: "Which region?"})

    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
    assert has_element?(view, "[data-qa='answer-field']", "Which database?")

    view |> form("#answer-question-form", %{"answer" => "Postgres"}) |> render_submit()
    view |> form("#answer-question-form", %{"answer" => "eu-west-1"}) |> render_submit()

    # Nothing reaches the agent until the whole round is answered and sent.
    assert %Run{pending_answer: nil} = Repo.reload!(run)

    view |> element("#send-answers-button") |> render_click()

    assert [] = Pipeline.list_questions(task, status: :pending)
  end

  test "a question its run moved on from is still answered here and sent", %{conn: conn, task: task, run: run} do
    parked = Repo.preload(run, task: :issue)
    {:ok, question} = Pipeline.register_question(parked, %DetectedQuestion{prompt: "Rebase onto main?"})

    # Updating the branch resumes the run without anyone answering what it asked.
    {:ok, _resumed} = run |> Repo.reload!() |> Pipeline.update_run(%{status: :finished})

    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
    assert has_element?(view, "[data-qa='answer-field']", "Rebase onto main?")

    view |> form("#answer-question-form", %{"answer" => "Yes"}) |> render_submit()
    view |> element("#send-answers-button") |> render_click()

    assert {:ok, %{status: :answered, delivered_at: %DateTime{}}} = Pipeline.get_question(question.id)
  end

  test "a question can be dismissed instead of answered", %{conn: conn, task: task, run: run} do
    {:ok, blocked} = Pipeline.update_run(run, %{status: :blocked_on_input, stage_outcome: :in_progress})
    blocked = Repo.preload(blocked, task: :issue)

    {:ok, question} = Pipeline.register_question(blocked, %DetectedQuestion{prompt: "Which database?"})

    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    view |> element("#dismiss-question-button") |> render_click()

    assert {:ok, %{status: :dismissed}} = Pipeline.get_question(question.id)
  end

  test "a blank answer is not recorded", %{conn: conn, task: task, run: run} do
    {:ok, blocked} = Pipeline.update_run(run, %{status: :blocked_on_input, stage_outcome: :in_progress})
    blocked = Repo.preload(blocked, task: :issue)

    {:ok, question} = Pipeline.register_question(blocked, %DetectedQuestion{prompt: "Which database?"})

    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    view |> form("#answer-question-form", %{"answer" => "   "}) |> render_submit()

    assert {:ok, %{status: :pending}} = Pipeline.get_question(question.id)
  end

  # The ids come back from the browser, so a page drawn before a question went away can still name it.
  test "a question that is gone is neither answered nor dismissed", %{conn: conn, task: task, run: run} do
    {:ok, blocked} = Pipeline.update_run(run, %{status: :blocked_on_input, stage_outcome: :in_progress})
    blocked = Repo.preload(blocked, task: :issue)

    {:ok, question} = Pipeline.register_question(blocked, %DetectedQuestion{prompt: "Which database?"})

    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    view
    |> element("#answer-question-form")
    |> render_submit(%{"question_id" => "qst_gone", "answer" => "Postgres"})

    view |> element("#dismiss-question-button") |> render_click(%{"question_id" => "qst_gone"})

    assert has_element?(view, "#question-prompt", "Which database?")
    assert {:ok, %{status: :pending}} = Pipeline.get_question(question.id)
  end

  test "a round sent from another tab leaves this one", %{conn: conn, task: task, run: run} do
    {:ok, blocked} = Pipeline.update_run(run, %{status: :blocked_on_input, stage_outcome: :in_progress})

    {:ok, question} =
      blocked |> Repo.preload(task: :issue) |> Pipeline.register_question(%DetectedQuestion{prompt: "Which database?"})

    {:ok, _answered} = Pipeline.answer_question(system_scope(), question, "Postgres")

    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
    view |> element("#change-answer-button") |> render_click()

    # A run with no conversation to resume takes the round without a word on its topic.
    _sent = Pipeline.send_answers(system_scope(), Repo.reload!(run))

    refute has_element?(view, "#answer-field-card")
  end

  describe "a round of three questions" do
    setup %{run: run} do
      {:ok, blocked} =
        Pipeline.update_run(run, %{
          status: :blocked_on_input,
          stage_outcome: :in_progress,
          conversation_id: "sess_round"
        })

      blocked = Repo.preload(blocked, task: :issue)

      {:ok, first} =
        Pipeline.register_question(blocked, %DetectedQuestion{prompt: "Which database?", options: ["Postgres", "MySQL"]})

      {:ok, second} = Pipeline.register_question(blocked, %DetectedQuestion{prompt: "Which region?"})
      {:ok, third} = Pipeline.register_question(blocked, %DetectedQuestion{prompt: "Who reviews it?"})

      %{questions: [first, second, third]}
    end

    test "a saved answer keeps its tab, marked answered, and the card moves on", %{conn: conn, task: task} do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      view |> form("#answer-question-form", %{"answer" => "Postgres"}) |> render_submit()

      assert has_element?(view, "#question-tabs #question-tab-2[role='tab']")
      refute has_element?(view, "#question-tabs #question-tab-3")
      assert has_element?(view, "#question-tab-0[aria-label='Question 1, answered']")
      assert has_element?(view, "#question-tab-1[aria-selected='true']")
      assert has_element?(view, "[data-qa='questions-pending-note']", "2 still to answer")

      view |> element("#question-tab-0") |> render_click()

      assert has_element?(view, "[data-qa='saved-answer']", "Postgres")
    end

    test "a replaced answer is the one that goes back", %{conn: conn, task: task, run: run} do
      stub(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      view |> form("#answer-question-form", %{"answer" => "Postgres"}) |> render_submit()
      view |> form("#answer-question-form", %{"answer" => "eu-west-1"}) |> render_submit()
      view |> form("#answer-question-form", %{"answer" => "Sam"}) |> render_submit()

      view |> element("#question-tab-0") |> render_click()
      view |> element("#change-answer-button") |> render_click()
      assert has_element?(view, "#answer-textarea", "Postgres")

      view |> form("#answer-question-form", %{"answer" => "Sqlite"}) |> render_submit()
      assert has_element?(view, "[data-qa='saved-answer']", "Sqlite")

      view |> element("#send-answers-button") |> render_click()

      lines = run |> Pipeline.list_run_events() |> Enum.map_join("\n", & &1.line)
      assert lines =~ "The answer is: Sqlite"
      refute lines =~ "Postgres"
    end

    test "answering every question keeps the card up and sends nothing until asked", %{
      conn: conn,
      task: task,
      run: run
    } do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      view |> form("#answer-question-form", %{"answer" => "Postgres"}) |> render_submit()
      view |> form("#answer-question-form", %{"answer" => "eu-west-1"}) |> render_submit()
      view |> form("#answer-question-form", %{"answer" => "Sam"}) |> render_submit()

      assert has_element?(view, "#question-tab-0[aria-label='Question 1, answered']")
      assert has_element?(view, "#question-tab-1[aria-label='Question 2, answered']")
      assert has_element?(view, "#question-tab-2[aria-label='Question 3, answered']")
      assert has_element?(view, "#question-tab-2[aria-selected='true']")
      assert has_element?(view, "[data-qa='saved-answer']", "Sam")
      assert has_element?(view, "#send-answers-button")
      refute has_element?(view, "#send-answers-button[disabled]")
      refute has_element?(view, "[data-qa='questions-pending-note']")

      assert %Run{pending_chat: nil} = Repo.reload!(run)
      assert Pipeline.list_run_events(run) == []
    end

    test "a dismissed question stays on the card and can be answered instead", %{
      conn: conn,
      task: task,
      questions: [first | _rest]
    } do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      view |> element("#dismiss-question-button") |> render_click()

      assert has_element?(view, "#question-tab-0[aria-label='Question 1, dismissed']")

      view |> element("#question-tab-0") |> render_click()
      assert has_element?(view, "[data-qa='dismissed-note']", "will carry on without an answer to this.")

      view |> element("#answer-instead-button") |> render_click()
      view |> form("#answer-question-form", %{"answer" => "Postgres"}) |> render_submit()

      assert {:ok, %{status: :answered, answer: "Postgres"}} = Pipeline.get_question(first.id)
      assert has_element?(view, "#question-tab-0[aria-label='Question 1, answered']")
    end

    test "a sent round leaves the card", %{conn: conn, task: task, questions: questions} do
      stub(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      view |> form("#answer-question-form", %{"answer" => "Postgres"}) |> render_submit()
      view |> form("#answer-question-form", %{"answer" => "eu-west-1"}) |> render_submit()
      view |> form("#answer-question-form", %{"answer" => "Sam"}) |> render_submit()
      view |> element("#send-answers-button") |> render_click()

      refute has_element?(view, "#answer-field-card")

      for question <- questions do
        assert {:ok, %{status: :answered, delivered_at: %DateTime{}}} = Pipeline.get_question(question.id)
      end
    end

    test "dismissing every question closes the round without a message", %{conn: conn, task: task, run: run} do
      reject(&Tools.start_os_process/2)

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      view |> element("#dismiss-question-button") |> render_click()
      view |> element("#dismiss-question-button") |> render_click()
      view |> element("#dismiss-question-button") |> render_click()

      assert has_element?(view, "[data-qa='dismissed-note']", "won't get a message about it.")
      refute has_element?(view, "#send-answers-button")

      view |> element("#dismiss-questions-button") |> render_click()

      refute has_element?(view, "#answer-field-card")
      assert has_element?(view, "[data-qa='rail-event']", "Questions dismissed. Nothing was sent to")
      assert %Run{status: :finished, pending_chat: nil} = Repo.reload!(run)
    end

    test "cancelling a change keeps the saved answer", %{conn: conn, task: task} do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      view |> form("#answer-question-form", %{"answer" => "Postgres"}) |> render_submit()
      view |> element("#question-tab-0") |> render_click()
      view |> element("#change-answer-button") |> render_click()
      view |> form("#answer-question-form", %{"answer" => "Half typed"}) |> render_change()
      view |> element("#cancel-answer-button") |> render_click()

      assert has_element?(view, "[data-qa='saved-answer']", "Postgres")
      refute has_element?(view, "#answer-textarea")
    end

    test "a change left unsaved holds the round back until it is saved or cancelled", %{conn: conn, task: task} do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      view |> form("#answer-question-form", %{"answer" => "Postgres"}) |> render_submit()
      view |> form("#answer-question-form", %{"answer" => "eu-west-1"}) |> render_submit()
      view |> form("#answer-question-form", %{"answer" => "Sam"}) |> render_submit()

      view |> element("#question-tab-0") |> render_click()
      view |> element("#change-answer-button") |> render_click()
      view |> form("#answer-question-form", %{"answer" => "Sqlite"}) |> render_change()

      assert has_element?(view, "#send-answers-button[disabled]")
      assert has_element?(view, "[data-qa='questions-pending-note']", "Save or cancel your change first")

      view |> element("#cancel-answer-button") |> render_click()

      refute has_element?(view, "#send-answers-button[disabled]")
    end

    test "a round dismissed from another tab leaves this one", %{conn: conn, task: task, run: run} do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      view |> element("#dismiss-question-button") |> render_click()
      view |> element("#dismiss-question-button") |> render_click()
      view |> element("#dismiss-question-button") |> render_click()
      assert has_element?(view, "#answer-field-card")

      {:ok, _closed} = run |> Repo.reload!() |> Repo.preload(:role) |> Pipeline.dismiss_round()

      refute has_element?(view, "#answer-field-card")
    end

    # The card shares the sidebar with the conversation, and the browser keeps the
    # reader's place there only while nothing the card does reaches the messages.
    test "using the card leaves the conversation as it was", %{conn: conn, task: task, run: run} do
      Pipeline.append_run_events(run.id, nil, [
        "[human] Where were we?",
        "[tool] Read lib/rail/repo.ex",
        "The schema needs a new column."
      ])

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      conversation = view |> element("#chat-messages") |> render()
      assert conversation =~ "The schema needs a new column."

      view |> element("#question-option-1") |> render_click()
      assert view |> element("#chat-messages") |> render() == conversation

      view |> form("#answer-question-form", %{"answer" => "MySQL"}) |> render_submit()
      assert view |> element("#chat-messages") |> render() == conversation

      view |> element("#dismiss-question-button") |> render_click()
      assert view |> element("#chat-messages") |> render() == conversation

      view |> element("#question-tab-0") |> render_click()
      assert view |> element("#chat-messages") |> render() == conversation

      view |> element("#change-answer-button") |> render_click()
      assert view |> element("#chat-messages") |> render() == conversation

      view |> element("#cancel-answer-button") |> render_click()
      assert view |> element("#chat-messages") |> render() == conversation
    end

    test "saving an answer with the raw log showing leaves the log as it was", %{conn: conn, task: task, run: run} do
      Pipeline.append_run_events(run.id, nil, [
        "[human] Where were we?",
        "[tool] Read lib/rail/repo.ex",
        "The schema needs a new column."
      ])

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      view |> element("#toggle-raw-log") |> render_click()
      log = view |> element("#raw-log-container") |> render()
      assert log =~ "The schema needs a new column."

      view |> form("#answer-question-form", %{"answer" => "Postgres"}) |> render_submit()

      assert view |> element("#raw-log-container") |> render() == log
    end

    test "a round sent from another tab adds its lines after the ones being read", %{
      conn: conn,
      task: task,
      run: run,
      questions: questions
    } do
      stub(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)

      Pipeline.append_run_events(run.id, nil, [
        "[human] Where were we?",
        "[tool] Read lib/rail/repo.ex",
        "The schema needs a new column."
      ])

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      earlier =
        view |> render() |> Floki.parse_fragment!() |> Floki.find("#chat-messages > *") |> Enum.map(&Floki.raw_html/1)

      assert length(earlier) == 3

      for question <- questions, do: {:ok, _answered} = Pipeline.answer_question(system_scope(), question, "Postgres")
      _sent = run |> Repo.reload!() |> Repo.preload(:role) |> then(&Pipeline.send_answers(system_scope(), &1))
      Pipeline.append_run_events(run.id, nil, ["[tool] Edit lib/rail/repo.ex", "Carrying on with Postgres."])

      _settled = render(view)
      assert has_element?(view, "[data-qa='role-bubble']", "Carrying on with Postgres.")

      {held, added} =
        view
        |> render()
        |> Floki.parse_fragment!()
        |> Floki.find("#chat-messages > *")
        |> Enum.split(length(earlier))

      assert Enum.map(held, &Floki.raw_html/1) == earlier
      assert Floki.attribute(added, "data-qa") == ["human-bubble", "activity-tile", "role-bubble"]
    end

    test "saving an answer the round already sent says so", %{conn: conn, task: task, questions: [first | _rest]} do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      view |> form("#answer-question-form", %{"answer" => "Postgres"}) |> render_submit()
      view |> element("#question-tab-0") |> render_click()
      view |> element("#change-answer-button") |> render_click()

      # Sent somewhere this page never heard about.
      {:ok, _sent} = first |> Repo.reload!() |> Question.changeset(%{delivered_at: DateTime.utc_now()}) |> Repo.update()

      view |> form("#answer-question-form", %{"answer" => "Sqlite"}) |> render_submit()

      assert has_element?(view, "#flash-error", "This round was already sent, so its answers can no longer be changed.")
      assert {:ok, %{answer: "Postgres"}} = Pipeline.get_question(first.id)
    end
  end

  test "cleaning up releases the disk the task was holding", %{conn: conn, task: task} do
    assert File.dir?(task.scratch_path)

    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    view |> element("#cleanup-task") |> render_click()

    assert_redirect(view, ~p"/issues/#{task.issue_id}", 1_000)
    refute File.dir?(task.scratch_path)
    assert {:ok, %Task{cleaned_up_at: %DateTime{}}} = Pipeline.get_task(task.id)
  end

  test "cleaning up warns when Linear has not marked the issue done", %{conn: conn, task: task, issue: issue} do
    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    assert has_element?(
             view,
             "#cleanup-task[data-confirm='TLV-1 is not marked done in Linear. Clean up this task anyway? Its worktree and scratch files will be deleted.']"
           )

    issue |> Issue.linear_changeset(%{state: :done}) |> Repo.update!()
    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    assert has_element?(
             view,
             "#cleanup-task[data-confirm='Clean up this task? Its worktree and scratch files will be deleted.']"
           )
  end

  # The worktree this would delete is the one every run on the task is working
  # in, so nothing is released while any of them is still in it.
  test "a task with something running cannot be cleaned up", %{conn: conn, task: task, run: run} do
    {:ok, _running} = Pipeline.update_run(run, %{status: :running})

    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    view |> element("#cleanup-task") |> render_click()
    render_async(view, 5_000)

    assert render(view) =~ "Stop the task&#39;s run before cleaning it up"
    assert File.dir?(task.scratch_path)
  end

  # Whatever went wrong down there, the reader is told rather than left with a
  # button that stays spinning.
  test "a cleanup that falls over says so", %{conn: conn, task: task} do
    stub(Git, :remove_worktree, fn _clone_path, _worktree -> raise "the disk went away" end)

    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    view |> element("#cleanup-task") |> render_click()
    render_async(view, 5_000)

    assert render(view) =~ "Could not clean up the task"
  end

  test "a task that is already gone reads as cleaned up", %{conn: conn} do
    assert {:ok, view, _html} = live(conn, ~p"/tasks/tsk_missing")

    assert has_element?(view, "#task-cleaned-up")
  end

  test "a task in a project the user cannot access reads as missing and shows nothing of it", %{
    conn: conn,
    task: task,
    run: run
  } do
    {:ok, blocked} = Pipeline.update_run(run, %{status: :blocked_on_input, stage_outcome: :in_progress})

    {:ok, %Question{}} =
      blocked |> Repo.preload(task: :issue) |> Pipeline.register_question(%DetectedQuestion{prompt: "Which database?"})

    {:ok, outsider} =
      Users.register_oauth_user(%{github_id: "gh_task_outsider", login: "task_outsider", email: "outsider@example.com"})

    {:ok, outsider} = Users.update_user(system_scope(), outsider, %{project_ids: ["prj_other"]})
    conn = log_in_user(conn, outsider)

    assert {:ok, view, html} = live(conn, ~p"/tasks/#{task.id}")

    assert has_element?(view, "#task-cleaned-up")
    refute html =~ "Task Live Issue"
    refute render(view) =~ "Task Live Issue"

    # Nor its questions, so there is no card to answer them from.
    refute has_element?(view, "[id^='question-card-']")
    refute html =~ "Which database?"
  end

  test "the owner menu offers only admins and the people granted the task's project", %{
    conn: conn,
    task: task,
    project: project
  } do
    linked = fn login, attrs ->
      {:ok, user} =
        Users.register_oauth_user(%{github_id: "gh_#{login}", login: login, name: login, email: "#{login}@example.com"})

      user |> Ecto.Changeset.change(Map.put(attrs, :linear_user_id, "lin_#{login}")) |> Repo.update!()
    end

    granted = linked.("granted_teammate", %{project_ids: [project.id]})
    elsewhere = linked.("elsewhere_teammate", %{project_ids: ["prj_other"]})
    admin = linked.("admin_teammate", %{admin: true})

    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}?tab=issue")

    assert has_element?(view, "#issue-assign-#{granted.id}")
    assert has_element?(view, "#issue-assign-#{admin.id}")
    refute has_element?(view, "#issue-assign-#{elsewhere.id}")
  end

  test "the Issue tab changes the owner and posts comments, as the issue page does", %{
    conn: conn,
    task: task,
    project: project
  } do
    {:ok, %{id: teammate_id} = teammate} =
      Users.register_oauth_user(%{github_id: "gh_tab_owner", login: "tab_owner", name: "Paulo Tab", email: "tab@x.io"})

    teammate |> Ecto.Changeset.change(linear_user_id: "lin_tab_owner", project_ids: [project.id]) |> Repo.update!()

    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}?tab=issue")
    Req.Test.allow(Rail.Linear, self(), view.pid)

    view |> element("#issue-owner-search-form") |> render_change(%{"q" => "nobody"})
    refute has_element?(view, "#issue-assign-#{teammate_id}")

    view |> element("#issue-owner-search-form") |> render_change(%{"q" => "paulo"})
    view |> element("#issue-assign-#{teammate_id}") |> render_click()

    assert has_element?(view, "#issue-owner", "Paulo Tab")
    assert %Issue{owner_user_id: ^teammate_id} = Repo.get!(Issue, task.issue_id)

    view |> element("#issue-assign-none") |> render_click()
    assert %Issue{owner_user_id: nil} = Repo.get!(Issue, task.issue_id)

    # Someone the menu does not offer cannot be assigned by a crafted event.
    render_click(view, "assign", %{"user_id" => "usr_not_offered"})
    assert %Issue{owner_user_id: nil} = Repo.get!(Issue, task.issue_id)

    view |> element("#issue-comment-form") |> render_change(%{"body" => "draft"})

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "commentCreate" => %{
            "success" => true,
            "comment" => %{"id" => "lin_tab_comment", "body" => "From the task", "issue" => %{"id" => "lin_task_live_1"}}
          }
        }
      })
    end)

    view |> element("#issue-comment-form") |> render_submit(%{"body" => "From the task"})

    assert has_element?(view, "#issue-comments", "From the task")
    assert has_element?(view, "#task-page")
  end

  test "a tab with no issue loaded changes nothing on an owner or comment event", %{
    conn: conn,
    task: task,
    scope: scope
  } do
    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
    refute has_element?(view, "#issue-page")

    render_click(view, "assign", %{"user_id" => scope.user.id})
    render_submit(view, "comment", %{"body" => "Nowhere to go"})

    assert %Issue{owner_user_id: nil} = Repo.get!(Issue, task.issue_id)
    assert has_element?(view, "#task-page")
  end

  test "a question that belongs to another task cannot be answered or dismissed from this one", %{
    conn: conn,
    task: task,
    project: project,
    role: role,
    run: run
  } do
    {:ok, blocked} = Pipeline.update_run(run, %{status: :blocked_on_input, stage_outcome: :in_progress})

    {:ok, %Question{id: own_id}} =
      blocked |> Repo.preload(task: :issue) |> Pipeline.register_question(%DetectedQuestion{prompt: "Which cache?"})

    other_issue =
      %Issue{}
      |> Issue.linear_changeset(%{
        project_id: project.id,
        external_id: "lin_task_live_other",
        identifier: "TLV-2",
        title: "Another task's issue",
        state: :todo
      })
      |> Repo.insert!()
      |> Repo.preload(:project)

    {:ok, other_task} = Pipeline.create_task(other_issue, :plan)
    on_exit(fn -> File.rm_rf(other_task.scratch_path) end)

    {:ok, other_run} =
      Pipeline.create_run(%{
        task_id: other_task.id,
        role_id: role.id,
        status: :blocked_on_input,
        stage_outcome: :in_progress,
        started_at: DateTime.utc_now()
      })

    {:ok, %Question{id: question_id}} =
      other_run
      |> Repo.preload(task: :issue)
      |> Pipeline.register_question(%DetectedQuestion{prompt: "Which database?"})

    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
    card = with_target(view, "#question-card-#{run.id}")

    render_submit(card, "answer_question", %{"question_id" => question_id, "answer" => "Postgres"})
    render_click(card, "dismiss_question", %{"question_id" => question_id})

    assert {:ok, %Question{status: :pending, answer: nil}} = Pipeline.get_question(question_id)
    assert {:ok, %Question{status: :pending}} = Pipeline.get_question(own_id)
  end

  describe "the tabs across the header" do
    test "the issue comes first and the stage's role is the one open", %{conn: conn, task: task, role: role} do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "#task-tab-issue", "Linear Issue")
      assert has_element?(view, "#task-tab-#{role.id}[aria-selected='true']", "review the plan")
      assert has_element?(view, "[data-qa='plan-stage']")
    end

    test "a tab shows the page-level progress bar while its stage loads", %{conn: conn, task: task} do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "#task-tab-issue[phx-click*='page_loading']")
    end

    test "the issue tab reads the ticket Linear has", %{conn: conn, task: task, issue: issue} do
      {:ok, _described} =
        Issues.update_issue(issue, %{
          description: "What the human asked for.\n\n![a shot](https://uploads.linear.app/ws/shot.png)",
          url: "https://linear.app/tlv/issue/TLV-1"
        })

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      view |> element("#task-tab-issue") |> render_click()

      assert has_element?(view, "[data-qa='issue-description']", "What the human asked for.")

      # Linear serves its own images only to a token, so they come back through Rail.
      assert render(view) =~ ~s(src="/issues/#{issue.id}/assets/ws/shot.png")
      assert has_element?(view, "#issue-linear-link[href='https://linear.app/tlv/issue/TLV-1']")

      # The issue is read on its own, and the task it is already on is not a link.
      refute has_element?(view, "[data-qa='plan-stage']")
      refute has_element?(view, "[data-qa='conversation-tab']")
      refute has_element?(view, "#task-conversation-column")
      refute has_element?(view, "[data-qa='issue-task-link']")
    end

    test "a role the task has moved past is read without its approval", %{
      conn: conn,
      task: task,
      role: role,
      project: project
    } do
      File.write!(Path.join([task.scratch_path, "tickets", "TLV-1.md"]), "The ticket as approved.")

      {:ok, engineer} = Roles.get_role(project_id: project.id, stage: :engineer)

      {:ok, task} = Pipeline.update_task(task, %{stage: :engineer})

      {:ok, _building} =
        Pipeline.create_run(%{
          task_id: task.id,
          role_id: engineer.id,
          status: :running,
          started_at: DateTime.utc_now()
        })

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      view |> element("#task-tab-#{role.id}") |> render_click()
      view |> element("#plan-item-ticket") |> render_click()

      assert has_element?(view, "[data-qa='plan_ticket']", "The ticket as approved.")
      refute has_element?(view, "[data-qa='approve_plan']")
    end

    test "a role with no stage of its own has only its conversation", %{
      conn: conn,
      task: task,
      project: project
    } do
      {:ok, debugger} = Roles.get_role(project_id: project.id, stage: :debugger)

      {:ok, _testing} =
        Pipeline.create_run(%{
          task_id: task.id,
          role_id: debugger.id,
          status: :running,
          started_at: DateTime.utc_now()
        })

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      view |> element("#task-tab-#{debugger.id}") |> render_click()

      assert has_element?(view, "[data-qa='role_no_work']")
      assert has_element?(view, "[data-qa='conversation-tab']")
    end

    test "a role that has not run has no tab yet", %{conn: conn, task: task, project: project} do
      {:ok, engineer} = Roles.get_role(project_id: project.id, stage: :engineer)

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      refute has_element?(view, "#task-tab-#{engineer.id}")
    end

    test "a blocked role counts what it is waiting on", %{conn: conn, task: task, role: role, run: run} do
      {:ok, blocked} = Pipeline.update_run(run, %{status: :blocked_on_input, stage_outcome: :in_progress})
      blocked = Repo.preload(blocked, task: :issue)

      {:ok, _first} = Pipeline.register_question(blocked, %DetectedQuestion{prompt: "Which flow?"})
      {:ok, _second} = Pipeline.register_question(blocked, %DetectedQuestion{prompt: "How many?"})

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "#task-tab-#{role.id} [data-qa='task-tab-badge']", "2")
      assert has_element?(view, "#task-tab-#{role.id}", "needs an answer")

      # An answer saved but not yet sent is not something the role is still waiting on.
      view |> form("#answer-question-form", %{"answer" => "Checkout"}) |> render_submit()
      assert has_element?(view, "#task-tab-#{role.id} [data-qa='task-tab-badge']", "1")

      view |> form("#answer-question-form", %{"answer" => "Three"}) |> render_submit()
      refute has_element?(view, "#task-tab-#{role.id} [data-qa='task-tab-badge']")
      assert has_element?(view, "#task-tab-#{role.id}", "needs an answer")
    end

    test "a task nothing has run on yet opens on the issue", %{conn: conn, task: task, run: run} do
      {:ok, _gone} = Repo.delete(run)

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "#task-tab-issue[aria-selected='true']")
      assert has_element?(view, "[data-qa='issue-page']")
    end

    test "the tab the URL names is the one that opens, and a move puts the new stage there", %{
      conn: conn,
      task: task,
      role: role,
      project: project
    } do
      {:ok, engineer} = Roles.get_role(project_id: project.id, stage: :engineer)

      {:ok, _building} =
        Pipeline.create_run(%{
          task_id: task.id,
          role_id: engineer.id,
          status: :running,
          started_at: DateTime.utc_now()
        })

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}?tab=#{role.id}")
      assert has_element?(view, "#task-tab-#{role.id}[aria-selected='true']")

      {:ok, _moved} = Pipeline.update_task(task, %{stage: :engineer})
      send(view.pid, :task_changed)

      assert has_element?(view, "#task-tab-#{engineer.id}[aria-selected='true']")
      assert_patch(view, ~p"/tasks/#{task.id}?tab=#{engineer.id}")
    end
  end

  describe "the Plan stage" do
    setup %{project: project, task: task, run: run} do
      {:ok, task} = Pipeline.update_task(task, %{worktree_path: create_temp_git_repo()})
      {:ok, run} = Pipeline.update_run(run, %{conversation_id: "sess_plan_stage"})
      design_dir = Path.join(task.scratch_path, "design")
      File.mkdir_p!(design_dir)
      stub(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)
      stub(Git, :get_or_create_worktree, fn _project, task -> {:ok, task.worktree_path} end)

      roles =
        Map.new([:product, :design, :architect, :engineer], fn stage ->
          {:ok, role} = Roles.get_role(project_id: project.id, stage: stage)
          {stage, role}
        end)

      save_ticket = fn ->
        description = "## Problem\n\nSlow.\n\n## Acceptance criteria\n\n- One\n- Two\n- Three\n- Four\n"
        {:ok, _ticket} = Pipeline.save_ticket(task, %{title: "Sandboxes show usage", description: description})
      end

      save_options = fn keys ->
        for key <- keys do
          File.write!(Path.join(design_dir, "#{key}.html"), "<h1>#{key}</h1>")
          File.write!(Path.join(design_dir, "#{key}.png"), "png bytes")
          title = String.capitalize(key)

          {:ok, _option} =
            Pipeline.save_design_option(task, %{
              key: key,
              title: title,
              summary: "#{title} summary.",
              good_at: ["Fast"],
              costs: ["Busy at 1280px"],
              assumptions: "Ten per page."
            })
        end
      end

      save_plan = fn design ->
        {:ok, _plan} =
          Pipeline.save_plan(task, %{
            plan: String.replace(@plan, "Extend the module.", "For #{design || "nobody"}."),
            design: design
          })
      end

      %{
        task: task,
        run: run,
        roles: roles,
        design_dir: design_dir,
        save_ticket: save_ticket,
        save_options: save_options,
        save_plan: save_plan
      }
    end

    test "a task shows the Linear Issue and Plan tabs only", %{conn: conn, task: task, role: role} do
      assert {:ok, view, html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "#task-tab-issue", "Linear Issue")
      assert has_element?(view, "#task-tab-#{role.id}[aria-selected='true']", "plan role")
      assert html |> Floki.parse_document!() |> Floki.find("[role='tab'][id^='task-tab-']") |> length() == 2
    end

    test "each output shows the moment it is saved, in every page open on the task", %{
      conn: conn,
      task: task,
      run: run,
      save_ticket: save_ticket,
      save_options: save_options,
      save_plan: save_plan
    } do
      {:ok, _working} = Pipeline.update_run(run, %{status: :running, stage_outcome: :in_progress})

      assert {:ok, one, _html} = live(conn, ~p"/tasks/#{task.id}")
      assert {:ok, two, _html} = live(conn, ~p"/tasks/#{task.id}")
      assert has_element?(one, "#plan-item-ticket-status", "Being written")
      assert has_element?(one, "#plan-ticket-pending", "Writing the ticket")

      save_ticket.()

      for view <- [one, two] do
        _settled = render(view)
        assert has_element?(view, "#plan-item-ticket-status", "4 criteria · saved")
        assert has_element?(view, "#plan-item-ticket-saved[phx-hook='LocalTime']")
        assert has_element?(view, "#plan-item-ticket[aria-current='true']")
      end

      save_options.(["cards"])

      for view <- [one, two] do
        _settled = render(view)
        assert has_element?(view, "#plan-item-design-status", "1 of 3 saved")
        assert has_element?(view, "#plan-item-ticket[aria-current='true']")
        assert has_element?(view, "[data-qa='plan_ticket']", "Slow.")
      end

      two |> element("#plan-item-design") |> render_click()
      assert has_element?(two, "#design-tab-cards", "Cards")
      assert has_element?(two, "#design-tab-building-2", "Being built")
      assert has_element?(two, "#pick-design-cards[disabled]")

      save_plan.(nil)

      for view <- [one, two] do
        _settled = render(view)
        assert has_element?(view, "#plan-item-plan-status", "saved")
        refute has_element?(view, "#approve-plan")
      end

      assert has_element?(one, "#plan-item-ticket[aria-current='true']")
      assert has_element?(two, "#plan-item-design[aria-current='true']")
    end

    test "a run starting, stopping or failing leaves the open item where it was", %{
      conn: conn,
      task: task,
      run: run,
      save_ticket: save_ticket
    } do
      {:ok, working} = Pipeline.update_run(run, %{status: :running, stage_outcome: :in_progress})

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      assert has_element?(view, "#plan-item-ticket[aria-current='true']")

      save_ticket.()
      _settled = render(view)
      assert has_element?(view, "#plan-item-design-status", "Not saved yet")
      assert has_element?(view, "#plan-item-ticket[aria-current='true']")

      {:ok, stopped} = Pipeline.update_run(working, %{status: :finished})
      send(view.pid, {:run_changed, run.id})

      assert has_element?(view, "#plan-item-ticket[aria-current='true']")
      refute has_element?(view, "#plan-item-plan[aria-current='true']")

      {:ok, restarted} = Pipeline.update_run(stopped, %{status: :running})
      send(view.pid, {:run_changed, run.id})

      assert has_element?(view, "#plan-item-ticket[aria-current='true']")
      refute has_element?(view, "#plan-item-design[aria-current='true']")

      {:ok, _failed} = Pipeline.update_run(restarted, %{status: :finished, error: "Plan ran out of turns."})
      send(view.pid, {:run_changed, run.id})

      assert has_element?(view, "[data-qa='task_status_chip']", "Plan failed")
      assert has_element?(view, "#plan-item-ticket[aria-current='true']")
      assert has_element?(view, "[data-qa='plan_ticket']", "Slow.")
    end

    test "Use this design picks at Plan, and the message says only what was picked", %{
      conn: conn,
      task: task,
      run: run,
      role: role,
      design_dir: dir,
      save_ticket: save_ticket,
      save_options: save_options
    } do
      save_ticket.()
      save_options.(["cards", "table", "timeline"])

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "[data-qa='task_status_chip']", "Pick a design")
      assert has_element?(view, "#task-tab-#{role.id}", "pick a design")
      assert has_element?(view, "#plan-item-design[aria-current='true']")
      assert has_element?(view, "#plan-item-design-status", "Pick one of 3")
      refute has_element?(view, "#approve-plan")

      view |> element("#design-tab-table") |> render_click()
      assert has_element?(view, "#design-option-title", "Table")

      view |> element("#pick-design-table") |> render_click()

      assert File.read!(Path.join(dir, "picked")) == "table"
      assert Enum.any?(Pipeline.list_run_events(run), &(&1.line =~ ~r/^\[human:[^\]]+\] I picked Table \(table\)\.$/))
      assert has_element?(view, "#plan-item-design-status", "Picked: Table")
      assert has_element?(view, "#plan-item-design[aria-current='true']")
      assert has_element?(view, "#design-option-table", "Picked")
      assert has_element?(view, "#design-costs", "Busy at 1280px")
      assert has_element?(view, "#design-assumptions", "Ten per page.")
      refute has_element?(view, "[role='tablist'][aria-label='Design options']")
    end

    test "a pick of another option than the plan's keeps Design open while Plan revises", %{
      conn: conn,
      task: task,
      save_ticket: save_ticket,
      save_options: save_options,
      save_plan: save_plan
    } do
      save_ticket.()
      save_options.(["cards", "table", "timeline"])
      save_plan.("cards")

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      assert has_element?(view, "#plan-item-design[aria-current='true']")

      view |> element("#design-tab-table") |> render_click()
      view |> element("#pick-design-table") |> render_click()

      assert has_element?(view, "#plan-item-design[aria-current='true']")
      assert has_element?(view, "#design-option-table", "Picked")
      assert has_element?(view, "#plan-item-plan-status", "Revising for the pick")
      refute has_element?(view, "#plan-item-plan[aria-current='true']")
    end

    test "each click opens its item, and coming back to the tab opens what waits on the human", %{
      conn: conn,
      task: task,
      role: role,
      save_ticket: save_ticket,
      save_options: save_options
    } do
      save_ticket.()
      save_options.(["cards", "table", "timeline"])

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      assert has_element?(view, "#plan-item-design[aria-current='true']")

      view |> element("#plan-item-ticket") |> render_click()
      assert has_element?(view, "#plan-item-ticket[aria-current='true']")
      assert has_element?(view, "[data-qa='plan_ticket']", "Slow.")

      view |> element("#plan-item-design") |> render_click()
      assert has_element?(view, "#plan-item-design[aria-current='true']")
      assert has_element?(view, "#design-tab-cards", "Cards")

      view |> element("#plan-item-plan") |> render_click()
      assert has_element?(view, "#plan-item-plan[aria-current='true']")
      assert has_element?(view, "#plan-plan-pending")

      view |> element("#task-tab-issue") |> render_click()
      refute has_element?(view, "[data-qa='plan-stage']")

      view |> element("#task-tab-#{role.id}") |> render_click()
      assert has_element?(view, "#plan-item-design[aria-current='true']")
      assert has_element?(view, "#plan-item-design-status", "Pick one of 3")
    end

    test "a pick of another option than the plan's says it is being revised, and offers no Approve", %{
      conn: conn,
      task: task,
      run: run,
      design_dir: dir,
      save_ticket: save_ticket,
      save_options: save_options,
      save_plan: save_plan
    } do
      save_ticket.()
      save_options.(["cards", "table", "timeline"])
      save_plan.("cards")
      File.write!(Path.join(dir, "picked"), "table")
      {:ok, working} = Pipeline.update_run(run, %{status: :running, stage_outcome: :in_progress})

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "#plan-item-plan[aria-current='true']")
      assert has_element?(view, "#plan-item-plan-status", "Revising for the pick")
      assert has_element?(view, "#plan-revising", "Being revised for Table. Below is the plan written for Cards.")
      refute has_element?(view, "#approve-plan")

      {:ok, _stopped} = Pipeline.update_run(working, %{status: :finished})
      send(view.pid, :task_changed)

      assert has_element?(view, "#plan-item-plan-status", "Written for Cards, not Table")
      assert has_element?(view, "#plan-revising", "Not yet revised for Table. Below is the plan written for Cards.")
      refute has_element?(view, "#approve-plan")

      File.rm!(Path.join([task.scratch_path, "plans", "TLV-1.design.json"]))
      send(view.pid, {:output_saved, task.id})
      _settled = render(view)
      assert has_element?(view, "#plan-revising", "Below is the plan written before the pick.")
    end

    test "Approve shows once the ticket, the pick and the plan for it are saved, and moves the task to Engineer", %{
      conn: conn,
      task: task,
      design_dir: dir,
      save_ticket: save_ticket,
      save_options: save_options,
      save_plan: save_plan
    } do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      refute has_element?(view, "#approve-plan")

      save_ticket.()
      save_options.(["cards", "table", "timeline"])
      save_plan.(nil)
      send(view.pid, {:output_saved, task.id})
      _settled = render(view)
      refute has_element?(view, "#approve-plan")

      File.write!(
        Path.join(dir, "manifest.json"),
        ~s({"options": [{"key": "table", "title": "Table", "summary": "Dense."}]})
      )

      File.write!(Path.join(dir, "picked"), "table")
      send(view.pid, {:output_saved, task.id})
      _settled = render(view)
      refute has_element?(view, "#approve-plan")

      save_plan.("table")
      send(view.pid, {:output_saved, task.id})
      _settled = render(view)
      assert has_element?(view, "#approve-plan[phx-disable-with='Approving…']", "Approve")

      Req.Test.expect(Rail.Linear, fn conn ->
        Req.Test.json(conn, %{
          "data" => %{
            "fileUpload" => %{
              "success" => true,
              "uploadFile" => %{
                "uploadUrl" => "https://uploads.linear.app/put/tlv-1",
                "assetUrl" => "https://uploads.linear.app/assets/tlv-1-table.png",
                "headers" => []
              }
            }
          }
        })
      end)

      Req.Test.expect(Rail.Linear, fn conn -> Plug.Conn.send_resp(conn, 200, "") end)

      view |> element("#approve-plan") |> render_click()

      assert %Task{stage: :engineer} = Repo.reload!(task)
      assert %Issue{title: "Sandboxes show usage", description: description} = Repo.get!(Issue, task.issue_id)
      assert description =~ "## Design: Table"

      assert %ImplementationPlan{content: content} = Repo.get_by(ImplementationPlan, task_id: task.id)
      assert content =~ "For table."
    end

    test "an Approve clicked on a page that has not caught up is refused, and the page catches up", %{
      conn: conn,
      task: task,
      save_ticket: save_ticket,
      save_plan: save_plan
    } do
      save_ticket.()
      save_plan.(nil)

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      {:ok, _moved} = Pipeline.update_task(task, %{stage: :engineer})

      view |> element("#approve-plan") |> render_click()

      assert has_element?(view, "#plan-error", "This task is at Engineer, not Plan.")
      refute has_element?(view, "#approve-plan")
      assert has_element?(view, "[data-qa='task_status_chip']", "Queued for Engineer")
    end

    test "a page left open ignores another task's move", %{
      conn: conn,
      task: task,
      save_ticket: save_ticket,
      save_plan: save_plan
    } do
      save_ticket.()
      save_plan.(nil)

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      send(view.pid, {:pipeline_changed, "tsk_another"})

      assert has_element?(view, "#approve-plan")
    end

    test "approving a run that started working since the page loaded says so", %{
      conn: conn,
      task: task,
      run: run,
      save_ticket: save_ticket,
      save_plan: save_plan
    } do
      save_ticket.()
      save_plan.(nil)

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      {:ok, _working} = Pipeline.update_run(run, %{status: :running, stage_outcome: :in_progress})

      view |> element("#approve-plan") |> render_click()

      assert has_element?(view, "#plan-error", "Something is still running on this task.")
      assert %Task{stage: :plan} = Repo.reload!(task)
    end

    test "a turn that ended short shows its error, the options it is short of, and where to pick", %{
      conn: conn,
      task: task,
      run: run,
      save_ticket: save_ticket,
      save_options: save_options
    } do
      save_ticket.()
      save_options.(["cards", "table"])
      error = "The Plan agent saved 2 design options. It needs 3, or a pick."
      {:ok, _failed} = Pipeline.update_run(run, %{error: error, stage_outcome: :in_progress})

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "[data-qa='task_status_chip']", "Plan failed")
      assert has_element?(view, "[data-qa='task_error_card']", error)
      assert has_element?(view, "#plan-item-design[aria-current='true']")
      assert has_element?(view, "#plan-item-design-status", "2 of 3 saved: needs 3")
      assert has_element?(view, "#design-tab-missing-3", "Not saved")
      assert has_element?(view, "#pick-in-conversation", "Pick in the conversation.")
      refute has_element?(view, "#pick-design-cards")
      assert has_element?(view, "#plan-item-plan-status", "Not saved yet")
    end

    test "a stopped Plan run says how to pick it up: a message when it has a conversation, Retry when it has none", %{
      conn: conn,
      task: task,
      run: run
    } do
      {:ok, _stopped} = Pipeline.update_run(run, %{stage_outcome: :in_progress})

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      assert has_element?(view, "#plan-ticket-pending", "Send it a message in the conversation")

      {:ok, _moved} = Pipeline.update_run(Repo.reload!(run), %{conversation_id: nil})
      send(view.pid, :task_changed)

      view |> element("#plan-item-ticket") |> render_click()

      assert has_element?(
               view,
               "#plan-ticket-pending",
               "Retry it from the conversation to start it again from its brief."
             )

      view |> element("#plan-item-design") |> render_click()
      assert has_element?(view, "#plan-design-pending", "Retry it from the conversation")
      view |> element("#plan-item-plan") |> render_click()
      assert has_element?(view, "#plan-plan-pending", "Retry it from the conversation")
      assert has_element?(view, "#retry-run")
    end

    test "a change with no screen says so, and Approve needs only the ticket and the plan", %{
      conn: conn,
      task: task,
      save_ticket: save_ticket,
      save_plan: save_plan
    } do
      save_ticket.()
      save_plan.(nil)

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "[data-qa='task_status_chip']", "Review the plan")
      assert has_element?(view, "#plan-item-ticket[aria-current='true']")
      assert has_element?(view, "[data-qa='plan_ticket']", "Slow.")
      assert has_element?(view, "#plan-item-design-status", "No screen in this change")
      assert has_element?(view, "#approve-plan")

      view |> element("#plan-item-design") |> render_click()
      assert has_element?(view, "#plan-design-none", "No screen in this change")

      view |> element("#plan-item-plan") |> render_click()
      assert has_element?(view, "[data-qa='plan_plan']", "For nobody.")
    end

    test "a subagent line opens on its own transcript, a refused save with its reason", %{
      conn: conn,
      task: task,
      run: run
    } do
      Pipeline.append_run_events(run.id, nil, [
        "[subagent toolu_ar] architect · plan from the ticket",
        "[within toolu_ar] Reading the code.",
        "[within toolu_ar] [tool] mcp__rail__save_plan",
        "[within toolu_ar] [tool error mcp__rail__save_plan] Refused, nothing saved. plan: must open with the heading.",
        "[subagent end toolu_ar]"
      ])

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      refute has_element?(view, "[data-qa='subagent-transcript']")

      view |> element("[data-qa='subagent-block'][data-status='done'] button") |> render_click()
      assert has_element?(view, "[data-qa='subagent-transcript']", "Reading the code.")

      view |> element("[data-qa='subagent-transcript'] [data-qa='activity-tile'] button") |> render_click()
      assert has_element?(view, "[data-qa='subagent-transcript'] [data-qa='activity-step']", "must open with the heading")

      view |> element("[data-qa='subagent-block'][data-status='done'] > button") |> render_click()
      refute has_element?(view, "[data-qa='subagent-transcript']")
    end

    test "a plan in the sheet's sections draws its diagrams, Source shows each, and the item counts its files", %{
      conn: conn,
      task: task,
      save_ticket: save_ticket
    } do
      save_ticket.()
      {:ok, _plan} = Pipeline.save_plan(task, %{plan: sheet_plan()})

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      view |> element("#plan-item-plan") |> render_click()

      assert has_element?(view, "#plan-item-plan-status", "files · saved")
      assert has_element?(view, "#plan-plan #plan-sheet")
      refute has_element?(view, "figure [data-qa='plan_diagram_source']:not(.hidden)")

      view |> element("button[phx-value-view='change:source']") |> render_click()
      assert has_element?(view, "figure[id^='plan-diagram-change-'] [data-qa='plan_diagram_source']:not(.hidden)")

      view |> element("button[phx-value-view='call_flow:source']") |> render_click()
      assert has_element?(view, "figure[id^='plan-diagram-call_flow-'] [data-qa='plan_diagram_source']:not(.hidden)")

      view |> element("button[phx-value-view='change:diagram']") |> render_click()
      view |> element("button[phx-value-view='call_flow:diagram']") |> render_click()
      refute has_element?(view, "figure [data-qa='plan_diagram_source']:not(.hidden)")
    end

    test "after approval the tab shows the plan as approved, not what scratch says now", %{
      conn: conn,
      task: task,
      role: role,
      save_ticket: save_ticket,
      save_plan: save_plan
    } do
      save_ticket.()
      save_plan.(nil)

      Repo.insert!(%ImplementationPlan{
        task_id: task.id,
        content: "## Implementation plan\n\nAs approved.",
        captured_at: DateTime.utc_now()
      })

      {:ok, _moved} = Pipeline.update_task(task, %{stage: :engineer})

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}?tab=#{role.id}")
      view |> element("#plan-item-plan") |> render_click()

      assert has_element?(view, "#plan-approved", "Plan approved")
      assert has_element?(view, "[data-qa='plan_plan']", "As approved.")
      refute has_element?(view, "[data-qa='plan_plan']", "For nobody.")
      refute has_element?(view, "#approve-plan")
    end

    test "every refusal a raced click can meet says why", %{
      conn: conn,
      task: task,
      run: run,
      design_dir: dir,
      save_ticket: save_ticket,
      save_options: save_options,
      save_plan: save_plan
    } do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      stage = with_target(view, "#plan-stage")

      render_click(stage, "approve", %{})
      assert has_element?(view, "#plan-error", "Plan has not saved a ticket yet.")

      save_ticket.()
      render_click(stage, "approve", %{})
      assert has_element?(view, "#plan-error", "Plan has not saved a plan yet.")

      render_click(stage, "pick", %{"key" => "cards"})
      assert has_element?(view, "#plan-error", "No design options are saved yet.")

      save_options.(["cards", "table", "timeline"])
      save_plan.("cards")
      render_click(stage, "approve", %{})
      assert has_element?(view, "#plan-error", "Pick a design before approving.")

      render_click(stage, "pick", %{"key" => "grid"})
      assert has_element?(view, "#plan-error", "That design option no longer exists.")

      File.write!(Path.join(dir, "picked"), "table")
      render_click(stage, "approve", %{})
      assert has_element?(view, "#plan-error", "The plan is not written for the picked design yet.")

      render_click(stage, "pick", %{"key" => "cards"})
      assert has_element?(view, "#plan-error", "A design has already been picked.")

      save_plan.("table")
      File.touch!(Path.join(dir, "table.html"), System.os_time(:second) + 60)
      render_click(stage, "approve", %{})
      assert has_element?(view, "#plan-error", "The screenshot is older than the design. Ask Plan to retake it.")

      File.rm!(Path.join(dir, "table.png"))
      render_click(stage, "approve", %{})
      assert has_element?(view, "#plan-error", "The picked design has no screenshot yet.")

      File.rm!(Path.join(dir, "picked"))
      {:ok, _silent} = Pipeline.update_run(run, %{conversation_id: nil})
      send(view.pid, :task_changed)
      render_click(stage, "pick", %{"key" => "cards"})
      assert has_element?(view, "#plan-error", "Plan cannot be messaged yet.")
    end

    test "working in the question card does not read the outputs again", %{conn: conn, task: task, run: run} do
      {:ok, blocked} = Pipeline.update_run(run, %{status: :blocked_on_input, stage_outcome: :in_progress})
      blocked = Repo.preload(blocked, task: :issue)
      {:ok, _first} = Pipeline.register_question(blocked, %DetectedQuestion{prompt: "Which layout?", options: ["A", "B"]})
      {:ok, _second} = Pipeline.register_question(blocked, %DetectedQuestion{prompt: "How many per page?"})

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      reject(&Pipeline.read_design/2)
      reject(&Pipeline.read_plan/1)
      reject(&Pipeline.read_ticket/1)

      view |> form("#answer-question-form", %{"answer" => "A, please"}) |> render_change()
      view |> element("#question-option-1") |> render_click()
      view |> element("#question-tab-1") |> render_click()
      assert has_element?(view, "#question-prompt", "How many per page?")
    end
  end

  describe "comments on the picked design" do
    setup %{task: task, run: run} do
      {:ok, task} = Pipeline.update_task(task, %{worktree_path: create_temp_git_repo()})
      {:ok, run} = Pipeline.update_run(run, %{conversation_id: "sess_plan_comments"})
      dir = Path.join(task.scratch_path, "design")
      File.mkdir_p!(dir)
      stub(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)
      stub(Git, :get_or_create_worktree, fn _project, task -> {:ok, task.worktree_path} end)

      for key <- ["waiting-lanes", "one-queue"] do
        File.write!(Path.join(dir, "#{key}.html"), ~s(<label id="group-by-project">Group by project</label>))
        File.write!(Path.join(dir, "#{key}.png"), "png bytes")
      end

      File.write!(
        Path.join(dir, "manifest.json"),
        ~s({"options": [{"key": "waiting-lanes", "title": "Lanes by what they wait on"}, {"key": "one-queue", "title": "One queue"}]})
      )

      pick = fn ->
        File.write!(
          Path.join(dir, "manifest.json"),
          ~s({"options": [{"key": "waiting-lanes", "title": "Lanes by what they wait on"}]})
        )

        File.rm!(Path.join(dir, "one-queue.html"))
        File.write!(Path.join(dir, "picked"), "waiting-lanes")
      end

      element = %{
        "selector" => "#group-by-project",
        "text" => "Group by project",
        "tag" => "label",
        "html" => ~s(<label id="group-by-project">Group by project</label>),
        "width" => 160,
        "height" => 20,
        "x" => 1300,
        "y" => 90
      }

      %{task: task, run: run, dir: dir, pick: pick, element: element}
    end

    test "the Comment control sits above the frame, outside it, before and after a pick", %{
      conn: conn,
      task: task,
      pick: pick
    } do
      for picked? <- [false, true] do
        if picked?, do: pick.()
        assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
        view |> element("#plan-item-design") |> render_click()

        assert has_element?(view, "#design-comment-toggle")
        refute has_element?(view, "[id^='design-frame-'] #design-comment-control")

        html = view |> element("#design-frame-waiting-lanes") |> render()
        assert html |> Floki.parse_fragment!() |> Floki.find("button, form, a") == []
        assert :binary.match(render(view), "design-comment-control") < :binary.match(render(view), "design-frame-")
      end
    end

    test "before a pick Comment is disabled with its reason, and nothing turns commenting on", %{
      conn: conn,
      task: task,
      element: element
    } do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      view |> element("#plan-item-design") |> render_click()

      assert has_element?(view, "#design-comment-toggle[disabled]")
      assert has_element?(view, "#design-comment-hint", "Pick a design to comment on it.")

      view |> with_target("#plan-stage") |> render_click("toggle_commenting", %{})
      view |> with_target("#plan-stage") |> render_hook("select_element", element)

      assert has_element?(view, "#design-frame-waiting-lanes[data-commenting='false'][data-comments='false']")
      refute has_element?(view, "[data-qa='plan_comment_form']")
      refute has_element?(view, "#design-page-waiting-lanes-" <> "x")
      refute render(view) =~ "comments=1"
    end

    test "after the pick a clicked element opens the comment box, and saving adds a marker and a row", %{
      conn: conn,
      task: task,
      pick: pick,
      element: element
    } do
      pick.()
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      view |> element("#plan-item-design") |> render_click()

      assert has_element?(view, ~s(iframe[src*="comments=1"]))
      refute has_element?(view, ~s(#open-design-waiting-lanes[href*="comments=1"]))

      view |> with_target("#plan-stage") |> render_hook("select_element", element)
      refute has_element?(view, "[data-qa='plan_comment_form']")

      view |> element("#design-comment-toggle") |> render_click()
      assert has_element?(view, "#design-comment-toggle[aria-pressed='true']", "Commenting")
      assert has_element?(view, "#design-frame-waiting-lanes[data-commenting='true'].cursor-crosshair")

      view |> with_target("#plan-stage") |> render_hook("select_element", element)
      assert has_element?(view, "#design-frame-waiting-lanes [data-qa='plan_comment_form']", "Group by project")
      assert has_element?(view, "#design-frame-waiting-lanes[data-selected='#group-by-project']")

      view |> element("[data-qa='plan_comment_cancel']") |> render_click()
      refute has_element?(view, "[data-qa='plan_comment_form']")

      view |> with_target("#plan-stage") |> render_hook("select_element", element)
      view |> form("[data-qa='plan_comment_form']", %{"body" => "   "}) |> render_submit()
      assert has_element?(view, "[data-qa='plan_comment_form']")

      view |> form("[data-qa='plan_comment_form']", %{"body" => "Turn this on by default."}) |> render_submit()
      refute has_element?(view, "[data-qa='plan_comment_form']")

      [frame] = view |> render() |> Floki.parse_document!() |> Floki.find("#design-frame-waiting-lanes")

      assert [[%{"number" => 1, "selector" => "#group-by-project", "id" => "pcm_" <> _rest}]] =
               frame |> Floki.attribute("data-markers") |> Enum.map(&Jason.decode!/1)

      assert has_element?(view, "#plan-comment-tray [data-qa='plan_comment_row']", "Turn this on by default.")
      assert has_element?(view, "#send-plan-comments", "Send 1")

      view |> with_target("#plan-stage") |> render_hook("stop_commenting", %{})
      assert has_element?(view, "#design-comment-toggle[aria-pressed='false']")
    end

    test "a kept state is taken back after a reload only on the pick while Plan can be messaged", %{
      conn: conn,
      task: task,
      run: run,
      pick: pick,
      element: element
    } do
      kept = %{"commenting" => true, "draft" => Map.merge(element, %{"option_key" => "waiting-lanes", "body" => "Half"})}

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      view |> element("#plan-item-design") |> render_click()
      view |> with_target("#plan-stage") |> render_hook("restore_commenting", kept)
      refute has_element?(view, "[data-qa='plan_comment_form']")
      assert has_element?(view, "#design-frame-waiting-lanes[data-commenting='false']")

      pick.()
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      view |> element("#plan-item-design") |> render_click()
      other = put_in(kept, ["draft", "option_key"], "one-queue")
      view |> with_target("#plan-stage") |> render_hook("restore_commenting", other)
      assert has_element?(view, "#design-frame-waiting-lanes[data-commenting='false']")

      view |> with_target("#plan-stage") |> render_hook("restore_commenting", kept)
      assert has_element?(view, "#design-frame-waiting-lanes[data-commenting='true']")
      assert has_element?(view, "[data-qa='plan_comment_body']", "Half")
      assert has_element?(view, "[data-qa='plan_comment_form']", "Group by project")

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      view |> element("#plan-item-design") |> render_click()

      view
      |> with_target("#plan-stage")
      |> render_hook("restore_commenting", %{"commenting" => true, "draft" => nil})

      assert has_element?(view, "#design-frame-waiting-lanes[data-commenting='true']")

      Repo.update_all(from(r in Run, where: r.id == ^run.id), set: [conversation_id: nil])
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      view |> element("#plan-item-design") |> render_click()
      view |> with_target("#plan-stage") |> render_hook("restore_commenting", kept)
      assert has_element?(view, "#design-frame-waiting-lanes[data-commenting='false']")
      assert has_element?(view, "#design-comment-toggle[disabled]")
      assert has_element?(view, "#design-comment-hint", "Cannot chat with plan role yet")
    end

    test "unsent comments are read again on a fresh mount, and another person never sees them", %{
      conn: conn,
      task: task,
      scope: scope,
      run: run,
      pick: pick,
      element: element
    } do
      pick.()

      {:ok, %{id: id}} =
        Pipeline.create_plan_comment(scope, run, %{
          target: :design,
          option_key: "waiting-lanes",
          selector: element["selector"],
          element_text: element["text"],
          element_tag: element["tag"],
          capture: %{html: element["html"], width: 160, height: 20},
          body: "Turn this on by default."
        })

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      view |> element("#plan-item-design") |> render_click()
      assert has_element?(view, "#plan-comment-#{id}")
      assert render(view) =~ id

      {:ok, someone} =
        Users.register_oauth_user(%{github_id: "gh_task_live_pcm", login: "someone_pcm", email: "pcm@example.com"})

      {:ok, someone} = Users.update_user(system_scope(), someone, %{project_ids: [task.project_id]})
      assert {:ok, theirs, _html} = live(log_in_user(build_conn(), someone), ~p"/tasks/#{task.id}")
      theirs |> element("#plan-item-design") |> render_click()
      refute has_element?(theirs, "#plan-comment-tray")
      refute render(theirs) =~ id

      view |> element("#send-plan-comments") |> render_click()
      _settled = render(theirs)
      refute has_element?(theirs, "#plan-comment-tray")
      refute has_element?(theirs, ~s(#design-frame-waiting-lanes[data-markers*="#{id}"]))
    end

    test "Send posts one message that reads as a card, and every tab of the author's empties without a reload", %{
      conn: conn,
      task: task,
      scope: scope,
      run: run,
      pick: pick,
      element: element
    } do
      pick.()

      attrs = %{
        target: :design,
        option_key: "waiting-lanes",
        selector: element["selector"],
        element_text: element["text"],
        element_tag: element["tag"],
        capture: %{html: element["html"], width: 160, height: 20},
        body: "Turn this on by default."
      }

      {:ok, _first} = Pipeline.create_plan_comment(scope, run, attrs)
      {:ok, %{id: gone_id}} = Pipeline.create_plan_comment(scope, run, %{attrs | selector: "#gone", body: "This went."})

      assert {:ok, one, _html} = live(conn, ~p"/tasks/#{task.id}")
      assert {:ok, two, _html} = live(conn, ~p"/tasks/#{task.id}")
      for view <- [one, two], do: view |> element("#plan-item-design") |> render_click()

      one |> with_target("#conversation-tab-root") |> render_hook("plan_comment_anchors", %{"missing" => [gone_id]})
      assert has_element?(one, "#plan-comment-#{gone_id}[data-found='false']", "No longer found")
      assert has_element?(two, "#plan-comment-#{gone_id}[data-found='true']")

      one |> element("#send-plan-comments") |> render_click()

      assert has_element?(one, "[data-qa='plan_comment_card']", "2 comments on the design")
      assert has_element?(one, "[data-qa='plan_comment_card']", "This went.")

      for view <- [one, two] do
        _settled = render(view)
        refute has_element?(view, "#plan-comment-tray")
        [frame] = view |> render() |> Floki.parse_document!() |> Floki.find("#design-frame-waiting-lanes")
        assert Floki.attribute(frame, "data-markers") == ["[]"]
      end

      two |> with_target("#conversation-tab-root") |> render_click("send_plan_comments", %{})
      assert Enum.count(Pipeline.list_run_events(run), &(&1.line =~ "comments on the design")) == 1
    end

    test "a round queued on a working Plan and then cancelled comes back to the tray, unlearned", %{
      conn: conn,
      task: task,
      scope: scope,
      run: run,
      pick: pick,
      element: element
    } do
      pick.()

      {:ok, %{id: id}} =
        Pipeline.create_plan_comment(scope, run, %{
          target: :design,
          option_key: "waiting-lanes",
          selector: element["selector"],
          element_text: element["text"],
          element_tag: element["tag"],
          capture: %{html: element["html"], width: 160, height: 20},
          body: "Turn this on by default."
        })

      {:ok, _running} = Pipeline.update_run(run, %{status: :running})
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      view |> element("#plan-item-design") |> render_click()
      assert has_element?(view, "#plan-comment-tray-hint", "Plan is working.")

      view |> element("#send-plan-comments") |> render_click()
      refute has_element?(view, "#plan-comment-tray")
      assert has_element?(view, "#queued-banner", "1 comment on the design")

      view |> element("#cancel-queued-message") |> render_click()

      assert has_element?(view, "#plan-comment-#{id}", "Turn this on by default.")
      refute has_element?(view, "#queued-banner")
      assert view |> element("#chat-input") |> render() =~ ~r{<textarea[^>]*></textarea>}
      assert [] = Repo.all(from o in Rail.Learnings.Schemas.Observation, where: o.task_id == ^task.id)
    end

    test "Remove takes a row and its marker away, also once the element is no longer found", %{
      conn: conn,
      task: task,
      scope: scope,
      run: run,
      pick: pick
    } do
      pick.()

      {:ok, %{id: id}} =
        Pipeline.create_plan_comment(scope, run, %{
          target: :design,
          option_key: "waiting-lanes",
          selector: "#gone",
          element_text: "",
          element_tag: "div",
          capture: %{html: "<div></div>", width: 10, height: 10},
          body: "Gone."
        })

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      view |> element("#plan-item-design") |> render_click()
      view |> with_target("#conversation-tab-root") |> render_hook("plan_comment_anchors", %{"missing" => [id]})
      view |> with_target("#conversation-tab-root") |> render_hook("plan_comment_anchors", %{"missing" => "nonsense"})
      assert has_element?(view, "#plan-comment-#{id}", "No longer found")

      view |> element("#plan-comment-tray-fold") |> render_click()
      refute has_element?(view, "#plan-comment-#{id}")
      view |> element("#plan-comment-tray-fold") |> render_click()

      view |> element("#remove-plan-comment-#{id}") |> render_click()
      refute has_element?(view, "#plan-comment-tray")
      assert Pipeline.list_plan_comments(scope, task) == []
      view |> with_target("#conversation-tab-root") |> render_click("remove_plan_comment", %{"id" => id})
    end

    # The approved plan is what Engineer builds from, so there is no conversation left to comment through.
    test "with the task at Engineer, the Plan tab reads as approved, its conversation closed and comments off", %{
      conn: conn,
      task: task,
      run: run,
      pick: pick
    } do
      pick.()
      {:ok, _plan} = Pipeline.save_plan(task, %{plan: @plan, design: "waiting-lanes"})
      {:ok, task} = Pipeline.update_task(task, %{stage: :engineer})
      Repo.insert!(%ImplementationPlan{task_id: task.id, content: @plan, captured_at: DateTime.utc_now()})

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}?tab=#{run.role_id}")
      view |> element("#plan-item-design") |> render_click()

      assert has_element?(view, "#task-conversation-column #conversation-closed", "this conversation is closed")
      refute has_element?(view, "#task-conversation-column textarea")
      refute has_element?(view, "#send-plan-comments")
      assert has_element?(view, "#design-comment-toggle[disabled]")
      assert has_element?(view, "#plan-stage", "The plan is approved, so the design takes no more comments.")
    end

    test "a comment the design or the chat moved under says why it was not saved", %{
      conn: conn,
      task: task,
      run: run,
      dir: dir,
      pick: pick,
      element: element
    } do
      pick.()
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      view |> element("#plan-item-design") |> render_click()
      view |> element("#design-comment-toggle") |> render_click()
      view |> with_target("#plan-stage") |> render_hook("select_element", element)
      view |> with_target("#plan-stage") |> render_hook("select_element", %{"selector" => 7})
      assert has_element?(view, "[data-qa='plan_comment_form']", "Group by project")
      view |> form("[data-qa='plan_comment_form']", %{"body" => "Typing"}) |> render_change()

      low = %{element | "y" => 900, "height" => 60}
      view |> with_target("#plan-stage") |> render_hook("select_element", low)
      assert view |> element("[data-qa='plan_comment_form']") |> render() =~ "bottom: calc(16.667% + 10px)"

      # An element covering the frame from its top has no room above or below, so the box opens inside it.
      tall = %{element | "y" => 0, "height" => 1080}
      view |> with_target("#plan-stage") |> render_hook("select_element", tall)
      style = view |> element("[data-qa='plan_comment_form']") |> render()
      assert style =~ "top: calc(0.0% + 10px)"
      refute style =~ "bottom: calc("

      scrolled = %{element | "y" => -400, "height" => 1300}
      view |> with_target("#plan-stage") |> render_hook("select_element", scrolled)
      assert view |> element("[data-qa='plan_comment_form']") |> render() =~ "top: calc(0.0% + 10px)"

      view |> with_target("#plan-stage") |> render_hook("select_element", element)
      assert view |> element("[data-qa='plan_comment_form']") |> render() =~ "top: calc(10.185% + 10px)"

      File.write!(
        Path.join(dir, "manifest.json"),
        ~s({"options": [{"key": "waiting-lanes", "title": "Lanes"}, {"key": "one-queue", "title": "One queue"}]})
      )

      File.write!(Path.join(dir, "picked"), "one-queue")
      view |> form("[data-qa='plan_comment_form']", %{"body" => "Moved under me."}) |> render_submit()
      assert has_element?(view, "#plan-error", "Only the picked design takes comments.")

      File.write!(Path.join(dir, "picked"), "waiting-lanes")
      _reread = render(view)
      view |> with_target("#plan-stage") |> render_hook("select_element", element)
      File.rm!(Path.join(dir, "picked"))
      view |> form("[data-qa='plan_comment_form']", %{"body" => "Unpicked under me."}) |> render_submit()
      assert has_element?(view, "#plan-error", "Pick a design to comment on it.")

      # A page opened once the pick is back can comment again.
      File.write!(Path.join(dir, "picked"), "waiting-lanes")
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      view |> element("#plan-item-design") |> render_click()
      view |> element("#design-comment-toggle") |> render_click()
      view |> with_target("#plan-stage") |> render_hook("select_element", element)
      Repo.update_all(from(r in Run, where: r.id == ^run.id), set: [conversation_id: nil])
      view |> form("[data-qa='plan_comment_form']", %{"body" => "Too late."}) |> render_submit()

      assert has_element?(view, "#plan-error", "Plan cannot be messaged yet.")
      refute has_element?(view, "[data-qa='plan_comment_form']")
      view |> with_target("#plan-stage") |> render_click("save_plan_comment", %{"body" => "No box."})
      view |> with_target("#plan-stage") |> render_click("change_plan_comment", %{"body" => "No box."})
    end
  end

  describe "comments on the ticket and the plan" do
    setup %{task: task, run: run} do
      {:ok, task} = Pipeline.update_task(task, %{worktree_path: create_temp_git_repo()})
      {:ok, run} = Pipeline.update_run(run, %{conversation_id: "sess_document_comments"})
      dir = Path.join(task.scratch_path, "design")
      File.mkdir_p!(dir)
      stub(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)
      stub(Git, :get_or_create_worktree, fn _project, task -> {:ok, task.worktree_path} end)

      File.write!(Path.join(dir, "waiting-lanes.html"), ~s(<label id="group-by-project">Group by project</label>))
      File.write!(Path.join(dir, "waiting-lanes.png"), "png bytes")
      File.write!(Path.join(dir, "manifest.json"), ~s({"options": [{"key": "waiting-lanes", "title": "Lanes"}]}))
      File.write!(Path.join(dir, "picked"), "waiting-lanes")

      description = """
      QA starts recording at first paint.

      ## Acceptance criteria

      - A recording starts on the loaded page.
      - A page that never goes idle starts after 10 seconds.

      | Page | Cap |
      |------|-----|
      | Overview | 5 s |

      ```
      settle_cap_ms: 10_000
      ```
      """

      {:ok, _ticket} =
        Pipeline.save_ticket(task, %{title: "Recordings settle", description: description, priority: :medium, estimate: 3})

      {:ok, _plan} = Pipeline.save_plan(task, %{plan: @plan, design: "waiting-lanes"})

      design = %{
        target: :design,
        option_key: "waiting-lanes",
        selector: "#group-by-project",
        element_text: "Group by project",
        element_tag: "label",
        capture: %{html: ~s(<label id="group-by-project">Group by project</label>), width: 160, height: 20},
        body: "Name the request."
      }

      key = fn label ->
        Enum.find(build_document_blocks(description), &(&1.label == label)).key
      end

      %{task: task, run: run, design: design, description: description, key: key}
    end

    test "the title, priority, estimate and every description line draw a +, and neither document has a Comment control",
         %{conn: conn, task: task} do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      view |> element("#plan-item-ticket") |> render_click()

      labels =
        view
        |> render()
        |> Floki.parse_document!()
        |> Floki.attribute("#plan-ticket [data-qa='line_comment_add']", "aria-label")

      assert labels == [
               "Comment on Title",
               "Comment on Priority",
               "Comment on Estimate",
               "Comment on Paragraph 1",
               "Comment on Heading 1",
               "Comment on Criterion 1",
               "Comment on Criterion 2",
               "Comment on Table header",
               "Comment on Table row 1",
               "Comment on Code line 1"
             ]

      assert has_element?(view, "#plan-ticket-priority", "Medium")
      assert has_element?(view, "#plan-ticket-estimate", "3 Points")
      refute has_element?(view, "#design-comment-toggle")

      view |> element("#plan-item-plan") |> render_click()
      assert has_element?(view, "#plan-sheet button[aria-label='Comment on Approach']")
      assert has_element?(view, "#plan-sheet button[aria-label='Comment on File 1']")
      refute has_element?(view, "#design-comment-toggle")
    end

    test "after a design comment, a comment on a criterion is card 2 under it and 2 in the tray, a second stacks as 3,
          and a teammate sees their own + but none of it",
         %{conn: conn, task: task, scope: scope, run: run, design: design, key: key} do
      {:ok, _design} = Pipeline.create_plan_comment(scope, run, design)
      criterion = key.("Criterion 2")

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      view |> element("#plan-item-ticket") |> render_click()
      view |> element("#line-ticket-#{criterion} [data-qa='line_comment_add']") |> render_click()

      assert has_element?(
               view,
               "#line-ticket-#{criterion} + [data-qa='line_comments'] form[data-qa='document_comment_form']"
             )

      view |> form("[data-qa='document_comment_form']", %{"body" => "  "}) |> render_submit()
      assert has_element?(view, "[data-qa='document_comment_form']")

      view |> form("[data-qa='document_comment_form']", %{"body" => "Make it 5."}) |> render_submit()
      refute has_element?(view, "[data-qa='document_comment_form']")

      under = "#line-ticket-#{criterion} + [data-qa='line_comments']"
      assert has_element?(view, "#{under} [data-qa='document_comment_number'][aria-label='Comment 2']")
      assert has_element?(view, "#plan-comment-tray [data-qa='plan_comment_row']:nth-child(2)", "Criterion 2")

      view |> element("#line-ticket-#{criterion} [data-qa='line_comment_add']") |> render_click()
      view |> form("[data-qa='document_comment_form']", %{"body" => "And say so."}) |> render_submit()
      assert has_element?(view, "#{under} [data-qa='document_comment']:nth-child(2) [aria-label='Comment 3']")

      view |> element("#plan-item-design") |> render_click()
      assert has_element?(view, "#design-comment-toggle")

      {:ok, someone} =
        Users.register_oauth_user(%{github_id: "gh_task_live_doc", login: "someone_doc", email: "doc@example.com"})

      {:ok, someone} = Users.update_user(system_scope(), someone, %{project_ids: [task.project_id]})
      assert {:ok, theirs, _html} = live(log_in_user(build_conn(), someone), ~p"/tasks/#{task.id}")
      theirs |> element("#plan-item-ticket") |> render_click()
      assert has_element?(theirs, "#line-ticket-#{criterion} [data-qa='line_comment_add']")
      refute has_element?(theirs, "[data-qa='document_comment']")
      refute has_element?(theirs, "#plan-comment-tray")
    end

    test "one Send posts one card grouped under the design, the ticket and the plan, and every tab empties", %{
      conn: conn,
      task: task,
      scope: scope,
      run: run,
      design: design,
      key: key
    } do
      {:ok, _design} = Pipeline.create_plan_comment(scope, run, design)

      assert {:ok, one, _html} = live(conn, ~p"/tasks/#{task.id}")
      assert {:ok, two, _html} = live(conn, ~p"/tasks/#{task.id}")
      one |> element("#plan-item-ticket") |> render_click()
      one |> element("#line-ticket-#{key.("Criterion 1")} [data-qa='line_comment_add']") |> render_click()
      one |> form("[data-qa='document_comment_form']", %{"body" => "Which page?"}) |> render_submit()
      one |> element("#plan-item-plan") |> render_click()
      one |> element("#plan-sheet button[aria-label='Comment on File 1']") |> render_click()
      one |> form("[data-qa='document_comment_form']", %{"body" => "Wait on page-loading-stop."}) |> render_submit()

      two |> element("#plan-item-plan") |> render_click()
      _settled = render(two)
      assert has_element?(two, "#plan-sheet [data-qa='document_comment']", "Wait on page-loading-stop.")

      one |> element("#send-plan-comments") |> render_click()

      assert has_element?(one, "[data-qa='plan_comment_card']", "3 comments on the design, the ticket and the plan")
      assert has_element?(one, "[data-qa='plan_comment_card']", "Which page?")

      for view <- [one, two] do
        _settled = render(view)
        refute has_element?(view, "#plan-comment-tray")
        refute has_element?(view, "[data-qa='document_comment']")
      end
    end

    test "a resave that changes a commented paragraph moves its comment to the top, changed, and leaves the others",
         %{conn: conn, task: task, key: key, description: description} do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      view |> element("#plan-item-ticket") |> render_click()
      view |> element("#line-ticket-#{key.("Paragraph 1")} [data-qa='line_comment_add']") |> render_click()
      view |> form("[data-qa='document_comment_form']", %{"body" => "Say which pages."}) |> render_submit()
      view |> element("#line-ticket-#{key.("Criterion 1")} [data-qa='line_comment_add']") |> render_click()
      view |> form("[data-qa='document_comment_form']", %{"body" => "Kept."}) |> render_submit()

      {:ok, _ticket} =
        Pipeline.save_ticket(task, %{
          title: "Recordings settle",
          description: String.replace(description, "at first paint", "the moment the browser paints")
        })

      _settled = render(view)
      _settled = render(view)

      assert has_element?(view, "#ticket-changed-comments [data-lifted='true']", "Say which pages.")
      assert has_element?(view, "#ticket-changed-comments [data-qa='document_comment_quote']", "at first paint")
      assert has_element?(view, "#line-ticket-#{key.("Criterion 1")} + [data-qa='line_comments']", "Kept.")
      assert has_element?(view, "#plan-comment-tray [data-qa='plan_comment_changed']")
      assert has_element?(view, "#plan-comment-tray [data-qa='plan_comment_row'][data-found='false']", "Paragraph 1")
    end

    test "typing in a line's box keeps it, Remove on a card takes it away, and a box Plan can no longer take closes", %{
      conn: conn,
      task: task,
      run: run,
      key: key
    } do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      view |> element("#plan-item-ticket") |> render_click()
      view |> element("#line-ticket-#{key.("Criterion 1")} [data-qa='line_comment_add']") |> render_click()
      view |> form("[data-qa='document_comment_form']", %{"body" => "Half a"}) |> render_change()
      assert has_element?(view, "[data-qa='document_comment_body']", "Half a")

      view |> form("[data-qa='document_comment_form']", %{"body" => "Gone soon."}) |> render_submit()
      view |> element("[data-qa='document_comment_remove']") |> render_click()
      refute has_element?(view, "[data-qa='document_comment']")
      refute has_element?(view, "#plan-comment-tray")

      view |> with_target("#plan-stage") |> render_click("remove_plan_comment", %{"id" => "pcm_already_gone"})
      refute has_element?(view, "[data-qa='document_comment']")

      for {item, add} <- [
            {"#plan-item-ticket", "#line-ticket-#{key.("Criterion 1")} [data-qa='line_comment_add']"},
            {"#plan-item-plan", "#plan-sheet button[aria-label='Comment on Approach']"}
          ] do
        view |> element(item) |> render_click()
        view |> element(add) |> render_click()
        assert has_element?(view, "[data-qa='document_comment_form']")

        Repo.update_all(from(r in Run, where: r.id == ^run.id), set: [conversation_id: nil])
        send(view.pid, {:pipeline_changed, task.id})
        refute has_element?(view, "[data-qa='document_comment_form']")
        Repo.update_all(from(r in Run, where: r.id == ^run.id), set: [conversation_id: "sess_document_comments"])
        send(view.pid, {:pipeline_changed, task.id})
      end
    end

    test "a comment Plan can no longer take when it is saved says why", %{conn: conn, task: task, run: run, key: key} do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      view |> element("#plan-item-ticket") |> render_click()
      view |> element("#line-ticket-#{key.("Criterion 1")} [data-qa='line_comment_add']") |> render_click()
      Repo.update_all(from(r in Run, where: r.id == ^run.id), set: [conversation_id: nil])

      view |> form("[data-qa='document_comment_form']", %{"body" => "Too late."}) |> render_submit()

      assert has_element?(view, "#plan-error", "Plan cannot be messaged yet.")
      refute has_element?(view, "[data-qa='document_comment_form']")
    end

    test "with no conversation no line offers a +, and the tray keeps its comments without Send", %{
      conn: conn,
      task: task,
      scope: scope,
      run: run,
      design: design
    } do
      {:ok, _design} = Pipeline.create_plan_comment(scope, run, design)
      Repo.update_all(from(r in Run, where: r.id == ^run.id), set: [conversation_id: nil])
      {:ok, _ticket} = Pipeline.save_ticket(task, %{title: "Recordings settle", description: "Short.", estimate: 1})

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      view |> element("#plan-item-ticket") |> render_click()

      assert has_element?(view, "#plan-ticket-estimate", "1 Point")
      refute has_element?(view, "[data-qa='line_comment_add']")
      assert has_element?(view, "#plan-comment-tray")
      refute has_element?(view, "#send-plan-comments")

      view |> with_target("#plan-stage") |> render_click("open_document_comment", %{"doc" => "ticket", "key" => "x"})
      refute has_element?(view, "[data-qa='document_comment_form']")
    end

    test "after approval no line of the ticket or the plan offers a +, and the tray is gone with the composer", %{
      conn: conn,
      task: task,
      scope: scope,
      run: run,
      design: design
    } do
      {:ok, _design} = Pipeline.create_plan_comment(scope, run, design)
      {:ok, task} = Pipeline.update_task(task, %{stage: :engineer})
      Repo.insert!(%ImplementationPlan{task_id: task.id, content: @plan, captured_at: DateTime.utc_now()})

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}?tab=#{run.role_id}")
      view |> element("#plan-item-ticket") |> render_click()
      refute has_element?(view, "[data-qa='line_comment_add']")
      view |> element("#plan-item-plan") |> render_click()
      refute has_element?(view, "[data-qa='line_comment_add']")
      refute has_element?(view, "#plan-comment-tray")

      view |> with_target("#plan-stage") |> render_click("open_document_comment", %{"doc" => "plan", "key" => "x"})
      refute has_element?(view, "[data-qa='document_comment_form']")
    end
  end

  describe "the engineer stage" do
    setup %{project: project, task: task} do
      {:ok, role} = Roles.get_role(project_id: project.id, stage: :engineer)

      # The pane's buttons are about what is outstanding, so the worktree starts
      # where a finished round leaves it: committed and pushed.
      remote = create_temp_git_repo(prefix: "rail_git_remote", initial_commit: false)
      git!(remote, ["config", "receive.denyCurrentBranch", "ignore"])

      repo = create_temp_git_repo()
      git!(repo, ["remote", "add", "origin", remote])
      git!(repo, ["push", "origin", "main"])
      git!(repo, ["checkout", "-b", "feature"])
      File.write!(Path.join(repo, "shipped.ex"), "committed\n")
      git!(repo, ["add", "."])
      git!(repo, ["commit", "-m", "the engineer's work"])
      git!(repo, ["push", "--set-upstream", "origin", "feature"])

      {:ok, task} = Pipeline.update_task(task, %{stage: :engineer, worktree_path: repo})

      # Every push opens the task's pull request if it has none.
      Req.Test.stub(Client, fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", "/app/installations/" <> _id} ->
            Req.Test.json(conn, %{"token" => "ghs_token"})

          {"GET", _pulls} ->
            Req.Test.json(conn, [])

          {"POST", _pulls} ->
            conn
            |> Plug.Conn.put_status(201)
            |> Req.Test.json(%{"number" => 7, "html_url" => "https://github.com/org/repo/pull/7", "draft" => true})
        end
      end)

      {:ok, engineer_run} =
        Pipeline.create_run(%{
          task_id: task.id,
          role_id: role.id,
          status: :finished,
          stage_outcome: :done,
          conversation_id: "sess_engineer_stage",
          started_at: DateTime.utc_now()
        })

      %{task: task, role: role, engineer_run: engineer_run, repo: repo}
    end

    test "working in the question card does not read the diff, the worktree or CI again", %{
      conn: conn,
      task: task,
      engineer_run: run
    } do
      {:ok, blocked} = Pipeline.update_run(run, %{status: :blocked_on_input, stage_outcome: :in_progress})
      blocked = Repo.preload(blocked, task: :issue)

      {:ok, _first} =
        Pipeline.register_question(blocked, %DetectedQuestion{prompt: "Which database?", options: ["Postgres", "MySQL"]})

      {:ok, _second} = Pipeline.register_question(blocked, %DetectedQuestion{prompt: "Which region?"})

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      reject(&Git.load_diff/3)
      reject(&Git.load_diff/4)
      reject(&Git.worktree_dirty?/1)
      reject(&Git.branch_unpushed?/1)
      reject(&Pipeline.get_ci_status/1)

      for typed <- [
            "U",
            "Us",
            "Use",
            "Use Postgres",
            "Use Postgres 16 with the default extensions, and keep the pool at ten connections"
          ] do
        view |> form("#answer-question-form", %{"answer" => typed}) |> render_change()
        assert has_element?(view, "#answer-textarea", typed)
      end

      view |> element("#question-option-1") |> render_click()
      assert has_element?(view, "#question-option-1.bg-blue-100")

      view |> element("#question-tab-1") |> render_click()
      assert has_element?(view, "#question-prompt", "Which region?")
    end

    test "the diff keeps refreshing under a draft, and the draft stays", %{
      conn: conn,
      task: task,
      engineer_run: run,
      repo: repo
    } do
      {:ok, blocked} = Pipeline.update_run(run, %{status: :blocked_on_input, stage_outcome: :in_progress})
      blocked = Repo.preload(blocked, task: :issue)
      {:ok, _question} = Pipeline.register_question(blocked, %DetectedQuestion{prompt: "Which database?"})

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      view |> form("#answer-question-form", %{"answer" => "Half typed"}) |> render_change()

      File.write!(Path.join(repo, "fresh.ex"), "just written\n")
      send(view.pid, {:run_events, run.id, []})
      # The page forwards to the stage, and the stage to the file it changed, each
      # on a turn of its own, so each needs a sync before the file can be read.
      _settled = render(view)
      _settled = render(view)

      assert has_element?(view, "[data-qa='diff-file-row']", "fresh.ex")
      assert has_element?(view, "#answer-textarea", "Half typed")
    end

    test "a draft typed in one view stays out of another view of the same task", %{
      conn: conn,
      task: task,
      engineer_run: run,
      repo: repo
    } do
      {:ok, blocked} = Pipeline.update_run(run, %{status: :blocked_on_input, stage_outcome: :in_progress})
      blocked = Repo.preload(blocked, task: :issue)
      {:ok, _question} = Pipeline.register_question(blocked, %DetectedQuestion{prompt: "Which database?"})

      assert {:ok, typing, _html} = live(conn, ~p"/tasks/#{task.id}")
      assert {:ok, idle, _html} = live(conn, ~p"/tasks/#{task.id}")
      typing |> form("#answer-question-form", %{"answer" => "Half typed"}) |> render_change()

      File.write!(Path.join(repo, "fresh.ex"), "just written\n")
      _logged = Pipeline.append_run_events(run.id, nil, ["[tool write_file] fresh.ex"])
      _settled = render(idle)
      _settled = render(idle)

      assert has_element?(idle, "[data-qa='diff-file-row']", "fresh.ex")
      refute has_element?(idle, "#answer-textarea", "Half typed")
      assert has_element?(typing, "#answer-textarea", "Half typed")
    end

    test "renders the diff the engineer produced", %{conn: conn, task: task} do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "#engineer-diff")
      assert has_element?(view, "[data-qa='diff-file-row']", "shipped.ex")
      assert has_element?(view, "#send-to-review")
      refute has_element?(view, "#commit-work")
    end

    test "with CI, the change waits on a pass before it can go to review", %{
      conn: conn,
      project: project,
      task: task,
      engineer_run: run
    } do
      {:ok, _project} = Projects.update_project(system_scope(), project, %{ci_command: "mise run ci"})
      stub(Git, :credential_env, fn _project -> {:ok, %{}} end)

      expect(Tools, :start_command_process, fn spawned, :ci, "mise run ci", _opts ->
        {:ok, %OsProcess{kind: :ci, run: spawned}}
      end)

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "#ci-status", "CI not run")
      assert has_element?(view, "#send-to-review[disabled]")
      refute has_element?(view, "#commit-work")

      view |> with_target("#engineer-stage") |> render_click("send_to_review", %{})
      assert has_element?(view, "#engineer-error", "CI has to pass on the latest commit before this goes to review.")

      view |> element("#run-ci", "Run CI") |> render_click()

      assert %Run{status: :running, ci_failure_streak: 0, review_on_ci_pass: true} = Repo.reload!(run)
    end

    test "with CI, a pass on the latest commit lets the change go to review", %{
      conn: conn,
      project: project,
      task: task,
      engineer_run: run,
      repo: repo
    } do
      {:ok, _project} = Projects.update_project(system_scope(), project, %{ci_command: "mise run ci"})

      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: task.id,
        kind: :ci,
        command: "mise run ci",
        exit_code: 0,
        head_sha: String.trim(git!(repo, ["rev-parse", "HEAD"])),
        stream_path: "/tmp/#{run.id}.log",
        status: :finished,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "#ci-status[title='mise run ci']", "CI passed")
      assert has_element?(view, "#send-to-review")
      refute has_element?(view, "#send-to-review[disabled]")
      refute has_element?(view, "#run-ci")
    end

    test "with CI, a failure says how many times it has gone back, and can be run again", %{
      conn: conn,
      project: project,
      task: task,
      engineer_run: run
    } do
      {:ok, _project} = Projects.update_project(system_scope(), project, %{ci_command: "mise run ci"})
      {:ok, run} = Pipeline.update_run(run, %{ci_failure_streak: 2})

      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: task.id,
        kind: :ci,
        exit_code: 1,
        stream_path: "/tmp/#{run.id}.log",
        status: :finished,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

      stub(Git, :credential_env, fn _project -> {:error, {:github_api_error, 401, %{}}} end)

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "#ci-status", "CI failed · 2 of 3")
      view |> element("#run-ci", "Run CI again") |> render_click()

      assert has_element?(view, "#engineer-error", "Could not start CI: {:github_api_error, 401, %{}}")
    end

    test "with CI running, the pane says so", %{conn: conn, project: project, task: task, engineer_run: run} do
      {:ok, _project} = Projects.update_project(system_scope(), project, %{ci_command: "mise run ci"})

      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: task.id,
        kind: :ci,
        stream_path: "/tmp/#{run.id}.log",
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "#ci-status", "CI running")
    end

    test "with CI failed and nobody sent back yet, it just says it failed", %{
      conn: conn,
      project: project,
      task: task,
      engineer_run: run
    } do
      {:ok, _project} = Projects.update_project(system_scope(), project, %{ci_command: "mise run ci"})

      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: task.id,
        kind: :ci,
        exit_code: 2,
        stream_path: "/tmp/#{run.id}.log",
        status: :finished,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "#ci-status", "CI failed")
      refute has_element?(view, "#ci-status", "of 3")
    end

    test "the header links the task's pull request", %{conn: conn, task: task} do
      {:ok, task} =
        Pipeline.update_task(task, %{pr_number: 12, pr_url: "https://github.com/org/app/pull/12", pr_is_draft: true})

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      assert has_element?(view, "#task-pull-request[href='https://github.com/org/app/pull/12']", "PR #12")
      refute has_element?(view, "#task-pull-request", "Draft")
    end

    test "updating the branch hands conflicts to the engineer and says it is updating", %{
      conn: conn,
      task: task,
      engineer_run: run
    } do
      expect(Git, :fetch_default_branch, fn _project, _path -> :ok end)
      expect(Git, :merge_default_branch, fn _scope, _task -> {:conflicts, ["shipped.ex"]} end)

      expect(Tools, :start_os_process, fn spawned, ["-p", prompt | _rest] ->
        assert prompt =~ "- shipped.ex"
        {:ok, %OsProcess{run: spawned}}
      end)

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      assert has_element?(view, "#update-branch[title='Merge origin/main into this branch']", "Update branch")
      assert has_element?(view, "#update-branch[phx-disable-with='Updating…']")

      view |> element("#update-branch") |> render_click()

      assert_patch(view, ~p"/tasks/#{task.id}?tab=#{run.role_id}")
      assert %Task{is_updating_branch: true} = Repo.reload!(task)
      assert %Run{status: :running} = Repo.reload!(run)
      assert has_element?(view, "#update-branch[disabled]", "Updating…")
    end

    # At Review the branch is the Review lead's: the merge runs on its run and shows on its tab.
    test "a clean merge into a task at Review leaves it there, pushes and starts the lead's next round", %{
      conn: conn,
      project: project,
      task: task,
      repo: repo
    } do
      {:ok, task} = Pipeline.update_task(task, %{stage: :review, pr_number: 7})
      {:ok, lead_role} = Roles.get_role(project_id: project.id, stage: :review_lead)

      {:ok, %Run{id: lead_run_id} = lead_run} =
        Pipeline.create_run(%{
          task_id: task.id,
          role_id: lead_role.id,
          status: :finished,
          stage_outcome: :done,
          started_at: DateTime.utc_now()
        })

      expect(Git, :fetch_default_branch, fn _project, _path -> :ok end)

      expect(Git, :merge_default_branch, fn _scope, _task ->
        git!(repo, ["commit", "--allow-empty", "-m", "merged main in"])
        :ok
      end)

      expect(Git, :push_branch, fn _scope, _task ->
        git!(repo, ["push", "origin", "feature"])
        :ok
      end)

      expect(Tools, :start_os_process, fn %Run{id: ^lead_run_id} = spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      view |> element("#update-branch") |> render_click()

      assert_patch(view, ~p"/tasks/#{task.id}?tab=#{lead_role.id}")
      assert %Task{stage: :review, is_updating_branch: false} = Repo.reload!(task)
      refute Git.branch_unpushed?(repo)

      assert ["[rail] Merged origin/main in.", "[rail] Round 1 started after it was pushed"] =
               lead_run |> Pipeline.list_run_events() |> Enum.map(& &1.line)
    end

    test "updating the branch says why for each way it can be refused", %{
      conn: conn,
      task: task,
      engineer_run: run,
      repo: repo
    } do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      expect(Git, :fetch_default_branch, fn _project, _path -> {:error, "could not read from remote"} end)
      view |> element("#update-branch") |> render_click()
      assert render(view) =~ "Could not update the branch: could not read from remote"

      expect(Git, :fetch_default_branch, fn _project, _path -> :ok end)
      expect(Git, :merge_default_branch, fn _scope, _task -> {:conflicts, ["shipped.ex"]} end)
      expect(Tools, :start_os_process, fn _spawned, _argv -> {:error, :dispatch_disabled} end)
      view |> element("#update-branch") |> render_click()
      assert render(view) =~ "Could not update the branch: :dispatch_disabled"

      {:ok, running} = Pipeline.update_run(Repo.reload!(run), %{status: :running})
      render_click(view, "update_branch", %{})
      assert render(view) =~ "Stop the task&#39;s run before updating its branch"

      {:ok, _idle} = Pipeline.update_run(running, %{status: :finished})
      File.rm_rf!(repo)
      render_click(view, "update_branch", %{})
      assert render(view) =~ "The task&#39;s worktree is gone, so there is nothing to update"
    end

    test "updating the branch says why when the branch cannot be handed back", %{conn: conn, task: task, repo: repo} do
      File.write!(Path.join(repo, "wip.ex"), "uncommitted\n")

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      view |> element("#update-branch") |> render_click()

      assert render(view) =~ "Commit the engineer&#39;s work before updating the branch"
      assert has_element?(view, "#update-branch:not([disabled])", "Update branch")
    end

    # Once Review has the task, its lead's engineer makes the fixes, so nothing here may commit or message.
    test "once the task has left Engineer, its tab offers no Commit, Run CI, Send to review or composer", %{
      conn: conn,
      project: project,
      task: task,
      engineer_run: run,
      repo: repo
    } do
      {:ok, _project} = Projects.update_project(system_scope(), project, %{ci_command: "mise run ci"})
      {:ok, _moved} = Pipeline.update_task(task, %{stage: :review})

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}?tab=#{run.role_id}")

      refute has_element?(view, "#run-ci")
      refute has_element?(view, "#send-to-review")
      refute has_element?(view, "#chat-composer-form")

      assert has_element?(
               view,
               "#task-conversation-column #conversation-closed",
               "The work is in Review now, so this conversation is closed: the Review lead's engineer makes its fixes."
             )

      # A page drawn before the task moved on can still send a message, and the closed conversation drops it.
      view |> with_target("#conversation-tab-root") |> render_click("send_chat", %{"message" => "One more thing"})
      refute Enum.any?(Pipeline.list_run_events(run), &(&1.line =~ "One more thing"))

      File.write!(Path.join(repo, "left_behind.ex"), "uncommitted\n")

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}?tab=#{run.role_id}")

      refute has_element?(view, "#commit-work")
    end

    test "says so when the engineer has changed nothing", %{conn: conn, task: task, repo: repo} do
      git!(repo, ["checkout", "main"])
      {:ok, _reset} = Pipeline.update_task(task, %{worktree_path: repo})

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "#engineer-work-pending-title", "Nothing changed yet")
      refute has_element?(view, "#send-to-review")
    end

    test "the filter switches between the branch and what is uncommitted", %{conn: conn, task: task, repo: repo} do
      File.write!(Path.join(repo, "wip.ex"), "uncommitted\n")

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "[data-qa='diff-file-row']", "shipped.ex")
      assert has_element?(view, "[data-qa='diff-file-row']", "wip.ex")

      view |> element("#diff-filter-uncommitted") |> render_click()

      refute has_element?(view, "[data-qa='diff-file-row']", "shipped.ex")
      assert has_element?(view, "[data-qa='diff-file-row']", "wip.ex")
    end

    # A view that happens to be empty is still a view: without the toolbar there
    # is no way back to the one that has the changes in it.
    test "an empty uncommitted view can still be switched out of", %{conn: conn, task: task} do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      view |> element("#diff-filter-uncommitted") |> render_click()

      assert has_element?(view, "[data-qa='diff_empty_state']", "Everything in the worktree is committed.")
      refute has_element?(view, "[data-qa='engineer_work_pending']")

      view |> element("#diff-filter-branch") |> render_click()
      assert has_element?(view, "[data-qa='diff-file-row']", "shipped.ex")
    end

    # The commit was made and the push was refused, so what is outstanding is the
    # push, and pressing the button again is what sends it.
    test "a push that failed is retried from the pane", %{conn: conn, task: task, engineer_run: run, repo: repo} do
      File.write!(Path.join(repo, "wip.ex"), "uncommitted\n")
      stub(Git, :push_branch, fn _scope, _task -> {:error, "remote rejected"} end)

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      view |> element("#commit-work") |> render_click()
      render_async(view, 5_000)

      assert has_element?(view, "#engineer-error", "remote rejected")
      assert has_element?(view, "#commit-work", "Push")

      stub(Git, :push_branch, fn _scope, %Task{worktree_path: path} ->
        git!(path, ["push", "--set-upstream", "origin", "HEAD"])
        :ok
      end)

      expect(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned, task: task}} end)

      view |> element("#commit-work") |> render_click()
      render_async(view, 5_000)

      refute has_element?(view, "#commit-work")
      assert %Run{error: nil} = Repo.reload!(run)
      assert %Task{stage: :review} = Repo.reload!(task)
    end

    # The push runs the repository's pre-push hooks, which can take minutes, so the
    # pane says it is pushing and will not take the click again meanwhile.
    test "a push in flight shows it and holds the buttons", %{conn: conn, task: task, repo: repo} do
      File.write!(Path.join(repo, "local.ex"), "one\n")
      git!(repo, ["add", "."])
      git!(repo, ["commit", "-m", "never pushed"])
      test_pid = self()

      stub(Git, :push_branch, fn _scope, %Task{worktree_path: path} ->
        send(test_pid, {:pushing, self()})

        receive do
          :release ->
            git!(path, ["push", "--set-upstream", "origin", "HEAD"])
            :ok
        end
      end)

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      view |> element("#commit-work", "Push") |> render_click()

      assert_receive {:pushing, pusher}
      assert has_element?(view, "#commit-work[disabled][aria-busy='true']", "Pushing…")
      assert has_element?(view, "#send-to-review[disabled]")

      # A second click while the first is in flight would only race it. The
      # button is disabled, so this is the event arriving anyway.
      view |> with_target("#engineer-stage") |> render_click("commit", %{})
      assert has_element?(view, "#commit-work[disabled][aria-busy='true']", "Pushing…")

      send(pusher, :release)
      render_async(view, 5_000)

      refute has_element?(view, "#commit-work")
      refute has_element?(view, "#send-to-review[disabled]")
    end

    # A push lasts as long as the repository's hooks do, and leaving the page
    # meanwhile takes back neither the commit nor the go-ahead that came with it.
    test "a commit carries on to review after the page is left", %{
      conn: conn,
      task: task,
      engineer_run: run,
      repo: repo
    } do
      File.write!(Path.join(repo, "wip.ex"), "uncommitted\n")
      {:ok, run} = Pipeline.update_run(run, %{error: "CI passed, but the branch could not be pushed: rejected"})
      test_pid = self()

      stub(Git, :push_branch, fn _scope, %Task{worktree_path: path} ->
        send(test_pid, {:pushing, self()})

        receive do
          :release ->
            git!(path, ["push", "origin", "HEAD"])
            :ok
        end
      end)

      expect(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned, task: task}} end)

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      view |> element("#commit-work") |> render_click()
      assert_receive {:pushing, pusher}

      Process.flag(:trap_exit, true)
      Process.exit(view.pid, :kill)
      pushing = Process.monitor(pusher)
      send(pusher, :release)
      assert_receive {:DOWN, ^pushing, :process, ^pusher, :normal}, 5_000

      assert %Task{stage: :review} = Repo.reload!(task)
      assert %Run{review_on_ci_pass: false, error: nil} = Repo.reload!(run)
    end

    # A push that takes the whole process down with it still has to leave the
    # pane usable rather than stuck on "Pushing…".
    test "a push that falls over releases the pane", %{conn: conn, task: task, repo: repo} do
      File.write!(Path.join(repo, "local.ex"), "one\n")
      git!(repo, ["add", "."])
      git!(repo, ["commit", "-m", "never pushed"])

      stub(Git, :push_branch, fn _scope, _task -> exit(:killed) end)

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      view |> element("#commit-work", "Push") |> render_click()
      render_async(view, 5_000)

      assert has_element?(view, "#engineer-error")
      refute has_element?(view, "#commit-work[aria-busy='true']")
    end

    test "marking a file read collapses it, for this reader only", %{conn: conn, task: task, scope: scope} do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      view |> element("[data-qa='diff-viewed-checkbox']") |> render_click()

      assert %{"shipped.ex" => _digest} = Git.list_viewed_files(scope, task)
      assert Git.list_viewed_files(user_scope(), task) == %{}

      refute has_element?(view, "[data-qa='diff_line_row']")

      view |> element("[data-qa='diff_collapse_toggle']") |> render_click()
      assert has_element?(view, "[data-qa='diff_line_row']")
    end

    # Reading and highlighting a large branch is the slow part, and the first page
    # is thrown away the moment the live view connects.
    test "the first page leaves the diff to the live view", %{conn: conn, task: task} do
      html = conn |> get(~p"/tasks/#{task.id}") |> html_response(200)

      assert html =~ "engineer_diff_loading"
      refute html =~ "diff_file_section"

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      assert has_element?(view, "[data-qa='diff_file_section']", "shipped.ex")
      refute has_element?(view, "[data-qa='engineer_diff_loading']")
    end

    # The header's buttons should not jump when the diff lands.
    test "the first page offers review before the diff arrives", %{conn: conn, task: task} do
      html = conn |> get(~p"/tasks/#{task.id}") |> html_response(200)

      assert html =~ ~s(data-qa="send_to_review")
    end

    test "the first page does not offer review for a branch that changed nothing", %{
      conn: conn,
      task: task,
      repo: repo
    } do
      git!(repo, ["checkout", "main"])

      html = conn |> get(~p"/tasks/#{task.id}") |> html_response(200)

      refute html =~ ~s(data-qa="send_to_review")
    end

    test "the first page counts a file git has never seen as work", %{conn: conn, task: task, repo: repo} do
      git!(repo, ["checkout", "main"])
      File.write!(Path.join(repo, "brand_new.ex"), "new\n")

      html = conn |> get(~p"/tasks/#{task.id}") |> html_response(200)

      assert html =~ ~s(data-qa="send_to_review")
    end

    test "marking a file reviewed does not read the diff again", %{conn: conn, task: task, repo: repo} do
      File.write!(Path.join(repo, "zeta.ex"), "also committed\n")
      git!(repo, ["add", "."])
      git!(repo, ["commit", "-m", "more work"])

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      reject(&Git.load_diff/3)
      reject(&Git.load_diff/4)

      view |> element("#diff-header-shipped-ex [data-qa='diff-viewed-checkbox']") |> render_click()

      assert has_element?(view, "#diff-header-shipped-ex [data-qa='diff-viewed-checkbox'][aria-pressed='true']")
      refute has_element?(view, "#diff-file-shipped-ex [data-qa='diff_line_row']")
      assert has_element?(view, "[data-qa='diff_viewed_progress']", "1/2")
      assert_push_event(view, "diff:scroll_to", %{path: "zeta.ex"})
    end

    # The browser morphs every element under a component a patch names, so a click
    # that named the stage would redraw every line of a large branch.
    test "marking a file reviewed patches the parts it changed, not the pane around them", %{
      conn: conn,
      task: task,
      repo: repo
    } do
      File.write!(Path.join(repo, "zeta.ex"), "also committed\n")
      git!(repo, ["add", "."])
      git!(repo, ["commit", "-m", "more work"])

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      [stage_cid] =
        view |> render() |> Floki.parse_fragment!() |> Floki.attribute("#engineer-stage", "data-phx-component")

      {_ref, _topic, proxy} = view.proxy
      1 = :erlang.trace(proxy, true, [:receive])

      view |> element("#diff-header-shipped-ex [data-qa='diff-viewed-checkbox']") |> render_click()
      _settled = render(view)
      :erlang.trace(proxy, false, [:receive])

      diffs =
        fn ->
          receive do
            {:trace, ^proxy, :receive, %Phoenix.Socket.Reply{payload: %{diff: diff}}} -> diff
            {:trace, ^proxy, :receive, %Message{event: "diff", payload: diff}} -> diff
            {:trace, ^proxy, :receive, _other} -> %{}
          after
            0 -> :done
          end
        end
        |> Stream.repeatedly()
        |> Enum.take_while(&(&1 != :done))

      assert Enum.any?(diffs, &Map.has_key?(&1, :c))

      for diff <- diffs do
        assert Map.keys(diff) -- [:c, :e] == []
        refute Map.has_key?(Map.get(diff, :c, %{}), String.to_integer(stage_cid))
      end

      assert has_element?(view, "#diff-header-shipped-ex [data-qa='diff-viewed-checkbox'][aria-pressed='true']")
      assert has_element?(view, "[data-qa='diff_viewed_progress']", "1/2")
      assert has_element?(view, "[data-qa='diff-file-row'][aria-current='true']", "zeta.ex")
    end

    # The pane is drawn whole from what it last drew whole, so being sent to a file
    # must not bring back the marks as they were then.
    test "a finding sending the reader to another file keeps the marks made since", %{
      conn: conn,
      task: task,
      repo: repo
    } do
      File.write!(Path.join(repo, "zeta.ex"), "also committed\n")
      git!(repo, ["add", "."])
      git!(repo, ["commit", "-m", "more work"])

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      view |> element("#diff-header-shipped-ex [data-qa='diff-viewed-checkbox']") |> render_click()

      render_patch(view, ~p"/tasks/#{task.id}?file=zeta.ex")

      assert has_element?(view, "#diff-scroller[data-scroll-to='zeta.ex']")
      assert has_element?(view, "#diff-header-shipped-ex [data-qa='diff-viewed-checkbox'][aria-pressed='true']")
      assert has_element?(view, "[data-qa='diff_viewed_progress']", "1/2")
    end

    test "a refresh after one file is edited patches that file, not the pane around it", %{
      conn: conn,
      task: task,
      engineer_run: run,
      repo: repo
    } do
      File.write!(Path.join(repo, "wip.ex"), "first draft\n")

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      [stage_cid] =
        view |> render() |> Floki.parse_fragment!() |> Floki.attribute("#engineer-stage", "data-phx-component")

      {_ref, _topic, proxy} = view.proxy
      1 = :erlang.trace(proxy, true, [:receive])

      File.write!(Path.join(repo, "wip.ex"), "second draft\n")
      send(view.pid, {:run_events, run.id, []})
      # The page forwards to the stage, and the stage to the file it changed, each
      # on a turn of its own, so each needs a sync before the file can be read.
      _settled = render(view)
      _settled = render(view)
      :erlang.trace(proxy, false, [:receive])

      diffs =
        fn ->
          receive do
            {:trace, ^proxy, :receive, %Message{event: "diff", payload: diff}} -> diff
            {:trace, ^proxy, :receive, _other} -> %{}
          after
            0 -> :done
          end
        end
        |> Stream.repeatedly()
        |> Enum.take_while(&(&1 != :done))

      assert Enum.any?(diffs, &Map.has_key?(&1, :c))

      for diff <- diffs do
        assert Map.keys(diff) -- [:c, :e] == []
        refute Map.has_key?(Map.get(diff, :c, %{}), String.to_integer(stage_cid))
      end

      assert has_element?(view, "[data-qa='diff_line_row']", "second draft")
      refute has_element?(view, "[data-qa='diff_line_row']", "first draft")
    end

    # The click came from a page drawn before the refresh, so it marked the old
    # version: the one on screen now has not been read.
    test "reviewing a version of a file the pane has moved past leaves it unread", %{
      conn: conn,
      task: task,
      engineer_run: run,
      repo: repo
    } do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      [old_digest] =
        view
        |> render()
        |> Floki.parse_fragment!()
        |> Floki.attribute("[data-qa='diff-viewed-checkbox']", "phx-value-digest")

      File.write!(Path.join(repo, "shipped.ex"), "rewritten\n")
      send(view.pid, {:run_events, run.id, []})
      _settled = render(view)

      view
      |> element("[data-qa='diff-viewed-checkbox']")
      |> render_click(%{"path" => "shipped.ex", "digest" => old_digest})

      assert has_element?(view, "[data-qa='diff-viewed-checkbox'][aria-pressed='false']")
      assert has_element?(view, "[data-qa='diff_viewed_progress']", "0/1")
    end

    test "a file edited after it was reviewed comes back unread with its new lines", %{
      conn: conn,
      task: task,
      engineer_run: run,
      repo: repo
    } do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      view |> element("[data-qa='diff-viewed-checkbox']") |> render_click()
      assert has_element?(view, "[data-qa='diff-viewed-checkbox'][aria-pressed='true']")

      File.write!(Path.join(repo, "shipped.ex"), "rewritten\n")
      send(view.pid, {:run_events, run.id, []})
      # The page forwards to the stage, and the stage to the file it changed, each
      # on a turn of its own, so each needs a sync before the file can be read.
      _settled = render(view)
      _settled = render(view)

      assert has_element?(view, "[data-qa='diff-viewed-checkbox'][aria-pressed='false']")
      assert has_element?(view, "[data-qa='diff_viewed_progress']", "0/1")

      view |> element("[data-qa='diff_collapse_toggle']") |> render_click()
      assert has_element?(view, "[data-qa='diff_line_row']", "rewritten")
      refute has_element?(view, "[data-qa='diff_line_row']", "committed")
    end

    test "the toolbar puts the file list away and narrows it down", %{conn: conn, task: task, repo: repo} do
      File.write!(Path.join(repo, "wip.ex"), "uncommitted\n")

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      view |> element("#diff-file-filter") |> render_change(%{"query" => "wip"})

      refute has_element?(view, "[data-qa='diff-file-row']", "shipped.ex")
      assert has_element?(view, "[data-qa='diff-file-row']", "wip.ex")
      # The counts are of the whole diff, whatever the query leaves showing.
      assert has_element?(view, "[data-qa='diff_viewed_progress']", "0/2")

      view |> element("#diff-toggle-files") |> render_click()
      refute has_element?(view, "#diff-file-tree")
    end

    test "uncommitted work offers a commit and refuses review until it is taken", %{
      conn: conn,
      task: task,
      repo: repo
    } do
      File.write!(Path.join(repo, "wip.ex"), "uncommitted\n")

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      stub(Git, :push_branch, fn _scope, %Task{worktree_path: path} ->
        git!(path, ["push", "--set-upstream", "origin", "HEAD"])
        :ok
      end)

      assert has_element?(view, "#commit-work")

      view |> element("#send-to-review") |> render_click()
      assert has_element?(view, "#engineer-error", "Commit the engineer's work before sending it to review.")

      view |> element("#commit-work") |> render_click()
      render_async(view, 5_000)

      assert git!(repo, ["log", "-1", "--pretty=%s"]) =~ "TLV-1: follow-up changes"
      refute has_element?(view, "#commit-work")
    end

    test "review is refused while the remote has not heard of the commits", %{
      conn: conn,
      task: task,
      repo: repo
    } do
      File.write!(Path.join(repo, "local.ex"), "one\n")
      git!(repo, ["add", "."])
      git!(repo, ["commit", "-m", "never pushed"])

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      view |> element("#send-to-review") |> render_click()

      assert has_element?(view, "#engineer-error", "Push the engineer's commits")
      assert %Task{stage: :engineer} = Repo.reload!(task)
    end

    test "sending the diff to review moves the task", %{conn: conn, task: task} do
      stub(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned, task: task}} end)

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      view |> element("#send-to-review") |> render_click()

      assert %Task{stage: :review} = Repo.reload!(task)
    end

    # A human's commit already says the work is ready, so nobody has to click on.
    test "committing the diff moves the task to review once it is pushed", %{conn: conn, task: task, repo: repo} do
      File.write!(Path.join(repo, "wip.ex"), "uncommitted\n")

      stub(Git, :push_branch, fn _scope, %Task{worktree_path: path} ->
        git!(path, ["push", "origin", "HEAD"])
        :ok
      end)

      expect(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned, task: task}} end)

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      view |> element("#commit-work") |> render_click()
      render_async(view, 5_000)

      assert %Task{stage: :review} = Repo.reload!(task)
      refute has_element?(view, "#engineer-error")
    end

    test "selecting a file in the tree marks it and goes there", %{conn: conn, task: task} do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      _clicked = view |> element("[data-qa='diff-file-row']") |> render_click()

      assert has_element?(view, "[data-qa='diff-file-row'][aria-current='true']", "shipped.ex")
      assert_push_event(view, "diff:scroll_to", %{path: "shipped.ex"})
    end

    test "marking a file reviewed goes on to the next unreviewed file", %{conn: conn, task: task, repo: repo} do
      File.write!(Path.join(repo, "zeta.ex"), "also committed\n")
      git!(repo, ["add", "."])
      git!(repo, ["commit", "-m", "more work"])

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      view |> element("#diff-header-shipped-ex [data-qa='diff-viewed-checkbox']") |> render_click()

      assert_push_event(view, "diff:scroll_to", %{path: "zeta.ex"})
      assert has_element?(view, "[data-qa='diff-file-row'][aria-current='true']", "zeta.ex")
    end

    test "selecting a file opens it again if reading it had folded it away", %{conn: conn, task: task} do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      view |> element("[data-qa='diff-viewed-checkbox']") |> render_click()
      refute has_element?(view, "[data-qa='diff_line_row']")

      _clicked = view |> element("[data-qa='diff-file-row']") |> render_click()

      assert has_element?(view, "[data-qa='diff_line_row']")
    end

    test "the file a finding sent the reader to stays open however read it is", %{conn: conn, task: task} do
      assert {:ok, read, _html} = live(conn, ~p"/tasks/#{task.id}")
      read |> element("[data-qa='diff-viewed-checkbox']") |> render_click()
      refute has_element?(read, "[data-qa='diff_line_row']")

      assert {:ok, sent, _html} = live(conn, ~p"/tasks/#{task.id}?file=shipped.ex")

      assert has_element?(sent, "[data-qa='diff_line_row']")
    end

    test "expanding a gap fills in the lines the diff left out", %{conn: conn, task: task, repo: repo} do
      File.write!(Path.join(repo, "wide.ex"), Enum.map_join(1..60, "", &"line #{&1}\n"))
      git!(repo, ["add", "."])
      git!(repo, ["commit", "-m", "wide"])

      File.write!(
        Path.join(repo, "wide.ex"),
        Enum.map_join(1..60, "", fn n -> if n in [1, 60], do: "changed #{n}\n", else: "line #{n}\n" end)
      )

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      # Against the branch wide.ex is one whole new file; the two edits to it only
      # read as two hunks with a gap between them once it is already committed.
      view |> element("#diff-filter-uncommitted") |> render_click()
      assert has_element?(view, "[data-qa='diff_gap_row']")

      view |> element("[data-qa='diff_gap_row']") |> render_click()

      refute has_element?(view, "[data-qa='diff_gap_row']")
      assert has_element?(view, "[data-qa='diff_line_row']", "line 30")
    end

    test "a commit git refused says why", %{conn: conn, task: task, repo: repo} do
      File.write!(Path.join(repo, "wip.ex"), "uncommitted\n")
      stub(Git, :commit_worktree, fn _scope, _task, _message -> {:error, :nothing_to_commit} end)

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      view |> element("#commit-work") |> render_click()
      render_async(view, 5_000)

      assert has_element?(view, "#engineer-error", "nothing left to commit")
    end

    test "a commit git refused in its own words repeats them", %{conn: conn, task: task, repo: repo} do
      File.write!(Path.join(repo, "wip.ex"), "uncommitted\n")
      stub(Git, :commit_worktree, fn _scope, _task, _message -> {:error, "index.lock exists"} end)

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      view |> element("#commit-work") |> render_click()
      render_async(view, 5_000)

      assert has_element?(view, "#engineer-error", "index.lock exists")
    end

    test "a push GitHub would not authorize says what came back", %{conn: conn, task: task, repo: repo} do
      File.write!(Path.join(repo, "wip.ex"), "uncommitted\n")

      Req.Test.stub(Client, fn req_conn ->
        req_conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "Not Found"})
      end)

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      view |> element("#commit-work") |> render_click()
      render_async(view, 5_000)

      assert has_element?(view, "#engineer-error", "Could not finish that:")
    end

    test "sending to review while the engineer works says why it did not", %{
      conn: conn,
      task: task,
      engineer_run: run
    } do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      {:ok, _working} = Pipeline.update_run(run, %{status: :running})
      view |> element("#send-to-review") |> render_click()

      assert has_element?(view, "#engineer-error", "still running")
      assert %Task{stage: :engineer} = Repo.reload!(task)
    end

    test "a cleaned-up worktree has no diff left to read", %{conn: conn, task: task} do
      {:ok, _gone} = Pipeline.update_task(task, %{worktree_path: "/tmp/gone_#{System.unique_integer([:positive])}"})

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "[data-qa='engineer_work_pending']")
    end

    test "keeps up with the worktree while the engineer works, at most every five seconds", %{
      conn: conn,
      task: task,
      engineer_run: run,
      repo: repo
    } do
      {:ok, _working} = Pipeline.update_run(run, %{status: :running})

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      refute has_element?(view, "[data-qa='diff-file-row']", "midway.ex")

      File.write!(Path.join(repo, "midway.ex"), "midway\n")
      send(view.pid, {:run_events, run.id, []})
      _settled = render(view)

      assert has_element?(view, "[data-qa='diff-file-row']", "midway.ex")

      # A second batch inside the window does not go back to git.
      File.write!(Path.join(repo, "later.ex"), "later\n")
      send(view.pid, {:run_events, run.id, []})
      _settled = render(view)

      refute has_element?(view, "[data-qa='diff-file-row']", "later.ex")
    end

    # The engineer changes the worktree, so a finished turn changes no row.
    test "re-reads the diff when a turn finishes", %{conn: conn, task: task, engineer_run: run, repo: repo} do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      refute has_element?(view, "[data-qa='diff-file-row']", "later.ex")

      File.write!(Path.join(repo, "later.ex"), "later\n")
      send(view.pid, {:os_process_finished, run, %{}})

      # The page forwards to the component, which renders on its own turn.
      _settled = render(view)
      assert has_element?(view, "[data-qa='diff-file-row']", "later.ex")
    end

    test "offers a comment on each line of the diff", %{conn: conn, task: task} do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "#diff-file-shipped-ex[data-comment-target] [data-qa='diff_comment_add']")
    end

    test "a comment saved on a line sits under it unsent, in either view, and tells the engineer nothing", %{
      conn: conn,
      task: task,
      engineer_run: run,
      repo: repo
    } do
      File.write!(Path.join(repo, "tracked.txt"), "one\ntwo\n")
      git!(repo, ["commit", "-am", "a second line"])
      File.write!(Path.join(repo, "tracked.txt"), "two\nthree\n")

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      stage = with_target(view, "#engineer-stage")

      render_click(stage, "open_diff_comment", %{
        "path" => "shipped.ex",
        "kind" => "added",
        "old_line" => "",
        "new_line" => "1"
      })

      view |> form("[data-qa='diff_comment_form']", %{"body" => "Say what was committed."}) |> render_submit()

      render_click(stage, "open_diff_comment", %{
        "path" => "tracked.txt",
        "kind" => "deleted",
        "old_line" => "1",
        "new_line" => ""
      })

      view |> form("[data-qa='diff_comment_form']", %{"body" => "Keep the first line."}) |> render_submit()

      assert has_element?(view, "#diff-file-shipped-ex [data-qa='diff_comment']", "Say what was committed.")
      assert has_element?(view, "#diff-file-tracked-txt [data-qa='diff_comment']", "Keep the first line.")
      assert has_element?(view, "#diff-file-tracked-txt [data-qa='diff_comment']", "Not sent")
      refute has_element?(view, "[data-qa='diff_comment_form']")

      view |> element("#diff-filter-uncommitted") |> render_click()

      render_click(stage, "open_diff_comment", %{
        "path" => "tracked.txt",
        "kind" => "context",
        "old_line" => "2",
        "new_line" => "1"
      })

      view |> form("[data-qa='diff_comment_form']", %{"body" => "Why keep this one?"}) |> render_submit()

      section = view |> element("#diff-file-tracked-txt") |> render() |> Floki.parse_fragment!() |> Floki.text()
      assert section =~ ~r/two.*Why keep this one\?.*three/s
      assert has_element?(view, "#send-diff-comments", "Send 3 comments")
      assert has_element?(view, "[data-qa='diff_comments_hint']", "Engineer is idle and starts on these at once.")
      assert Pipeline.list_run_events(run) == []
    end

    test "unsent comments are still there after a reload, and only their author sees them", %{
      conn: conn,
      task: task
    } do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      view
      |> with_target("#engineer-stage")
      |> render_click("open_diff_comment", %{
        "path" => "shipped.ex",
        "kind" => "added",
        "old_line" => "",
        "new_line" => "1"
      })

      view |> form("[data-qa='diff_comment_form']", %{"body" => "Say what was committed."}) |> render_submit()

      assert {:ok, again, _html} = live(conn, ~p"/tasks/#{task.id}")
      assert has_element?(again, "#diff-file-shipped-ex [data-qa='diff_comment']", "Say what was committed.")
      assert has_element?(again, "[data-qa='diff-file-row'] [data-qa='diff_file_unsent']", "1")

      {:ok, someone} =
        Users.register_oauth_user(%{github_id: "gh_task_live_other", login: "someone", email: "someone@example.com"})

      {:ok, someone} = Users.update_user(system_scope(), someone, %{project_ids: [task.project_id]})

      assert {:ok, theirs, _html} = live(log_in_user(build_conn(), someone), ~p"/tasks/#{task.id}")
      refute has_element?(theirs, "[data-qa='diff_comment']")
      refute has_element?(theirs, "#send-diff-comments")
      theirs |> element("#diff-list-comments", "Comments 0") |> render_click()
      assert has_element?(theirs, "#diff-comment-list", "Nobody has commented on this diff yet.")
    end

    test "everyone on the task sees sent and resolved comments as they happen, and only the author acts on them", %{
      task: task,
      scope: scope,
      engineer_run: run
    } do
      comment = %{path: "shipped.ex", line_kind: :added, line: 1, line_text: "committed", filter: :branch}
      {:ok, %{id: id}} = Pipeline.create_diff_comment(scope, task, Map.put(comment, :body, "Say what was committed."))

      {:ok, someone} =
        Users.register_oauth_user(%{github_id: "gh_task_live_other", login: "someone", email: "someone@example.com"})

      {:ok, someone} = Users.update_user(system_scope(), someone, %{project_ids: [task.project_id]})

      assert {:ok, theirs, _html} = live(log_in_user(build_conn(), someone), ~p"/tasks/#{task.id}")
      refute has_element?(theirs, "#diff-comment-#{id}")

      stub(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)
      {:ok, _delivery, _run} = Pipeline.send_diff_comments(scope, run)
      {:ok, _unsent} = Pipeline.create_diff_comment(scope, task, Map.put(comment, :body, "Still a draft."))

      # The page hears of it and forwards to the stage, each on a turn of its own.
      _settled = render(theirs)
      _settled = render(theirs)
      author = scope.user.name || scope.user.login
      assert has_element?(theirs, "#diff-comment-#{id}", author)
      assert has_element?(theirs, "#diff-comment-#{id}", "Sent")
      refute has_element?(theirs, "#diff-comment-#{id}", "You")
      refute has_element?(theirs, "#diff-comment-#{id} [data-qa='diff_comment_resolve']")
      refute has_element?(theirs, "[data-qa='diff_comment']", "Still a draft.")
      refute has_element?(theirs, "#send-diff-comments")

      theirs |> element("#diff-list-comments", "Comments 1") |> render_click()
      assert has_element?(theirs, "[data-qa='diff_comment_list_author']", author)
      refute has_element?(theirs, "[data-qa='diff_comment_list_resolve']")

      # A resolve forged from the teammate's page changes nothing.
      theirs
      |> with_target("#engineer-stage")
      |> render_click("resolve_diff_comment", %{"id" => id, "resolved" => "true"})

      assert [%{status: :sent}, %{status: :unsent}] = Pipeline.list_diff_comments(scope, task)

      [sent, _draft] = Pipeline.list_diff_comments(scope, task)
      {:ok, _resolved} = Pipeline.set_diff_comment_resolved(scope, sent, true)
      _settled = render(theirs)
      _settled = render(theirs)
      assert has_element?(theirs, "#diff-comment-#{id}[aria-expanded='false']", "Resolved")

      theirs |> element("#diff-comment-#{id}") |> render_click()
      assert has_element?(theirs, "#diff-comment-#{id}", "Say what was committed.")
      refute has_element?(theirs, "#diff-comment-#{id} [data-qa='diff_comment_unresolve']")

      assert {:ok, again, _html} = live(log_in_user(build_conn(), someone), ~p"/tasks/#{task.id}")
      assert has_element?(again, "#diff-comment-#{id}[aria-expanded='false']", "Resolved")
    end

    test "sending to an idle engineer starts a turn on one message holding every comment, and they stay, sent", %{
      conn: conn,
      task: task,
      scope: scope,
      repo: repo
    } do
      File.write!(Path.join(repo, "tracked.txt"), "two\nthree\n")
      comment = %{filter: :branch, body: "Why?"}

      for attrs <- [
            %{path: "shipped.ex", line_kind: :added, line: 1, line_text: "committed", body: "Say what was committed."},
            %{path: "tracked.txt", line_kind: :deleted, line: 1, line_text: "one", body: "Keep the first line."},
            %{path: "tracked.txt", line_kind: :added, line: 2, line_text: "three"}
          ] do
        {:ok, _saved} = Pipeline.create_diff_comment(scope, task, Map.merge(comment, attrs))
      end

      test_pid = self()

      expect(Tools, :start_os_process, fn spawned, argv ->
        send(test_pid, {:turn, argv})
        {:ok, %OsProcess{run: spawned}}
      end)

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      view |> element("#send-diff-comments", "Send 3 comments") |> render_click()

      assert_receive {:turn, argv}, 5_000
      assert Enum.join(argv, " ") =~ "3 comments on the diff"

      _settled = render(view)
      assert [bubble] = view |> render() |> Floki.parse_fragment!() |> Floki.find("[data-qa='human-bubble']")

      assert Floki.text(bubble) =~
               ~r/3 comments on the diff.*shipped\.ex, line 1.*\+ committed.*Say what was committed\./s

      assert Floki.text(bubble) =~ ~r/tracked\.txt, removed line 1.*- one.*Keep the first line\./s
      assert Floki.text(bubble) =~ ~r/tracked\.txt, line 2.*\+ three.*Why\?/s
      assert [_one, _two, _three] = view |> render() |> Floki.parse_fragment!() |> Floki.find("[data-qa='diff_comment']")
      assert has_element?(view, "#diff-file-shipped-ex [data-qa='diff_comment']", "Sent")
      refute has_element?(view, "[data-qa='diff_comment']", "Not sent")
      refute has_element?(view, "#send-diff-comments")
      refute has_element?(view, "[data-qa='diff_comments_hint']")
      refute has_element?(view, "[data-qa='diff_file_unsent']")
    end

    test "a comment written after a send is the only one sent next", %{
      conn: conn,
      task: task,
      scope: scope
    } do
      comment = %{path: "shipped.ex", line_kind: :added, line: 1, line_text: "committed", filter: :branch}
      {:ok, _first} = Pipeline.create_diff_comment(scope, task, Map.put(comment, :body, "First round, one."))
      {:ok, _second} = Pipeline.create_diff_comment(scope, task, Map.put(comment, :body, "First round, two."))
      test_pid = self()

      stub(Tools, :start_os_process, fn spawned, argv ->
        send(test_pid, {:turn, argv})
        {:ok, %OsProcess{run: spawned}}
      end)

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      view |> element("#send-diff-comments", "Send 2 comments") |> render_click()
      assert_receive {:turn, _first_round}, 5_000

      view
      |> with_target("#engineer-stage")
      |> render_click("open_diff_comment", %{
        "path" => "shipped.ex",
        "kind" => "added",
        "old_line" => "",
        "new_line" => "1"
      })

      view |> form("[data-qa='diff_comment_form']", %{"body" => "Second round."}) |> render_submit()
      view |> element("#send-diff-comments", "Send 1 comment") |> render_click()

      # The first round's turn is still going, so the second waits for it.
      assert has_element?(view, "#queued-banner", "1 comment on the diff")
      assert has_element?(view, "#queued-banner", "Second round.")
      refute has_element?(view, "#queued-banner", "First round")
      refute has_element?(view, "#send-diff-comments")
    end

    test "sending while the engineer works queues the message for when its turn ends", %{
      conn: conn,
      task: task,
      scope: scope,
      engineer_run: run
    } do
      {:ok, _working} = Pipeline.update_run(run, %{status: :running})
      reject(&Tools.start_os_process/2)

      {:ok, _saved} =
        Pipeline.create_diff_comment(scope, task, %{
          path: "shipped.ex",
          line_kind: :added,
          line: 1,
          line_text: "committed",
          filter: :branch,
          body: "Say what was committed."
        })

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      assert has_element?(view, "[data-qa='diff_comments_hint']", "Engineer is working. These wait until its turn ends.")

      view |> element("#send-diff-comments", "Send 1 comment") |> render_click()

      assert has_element?(view, "#queued-banner", "1 comment on the diff")
      assert has_element?(view, "[data-qa='diff_comment']", "Sent")
      refute has_element?(view, "#send-diff-comments")
    end

    test "a comment whose line the engineer rewrote is lifted, and still sent quoting the line as it was", %{
      conn: conn,
      task: task,
      scope: scope,
      engineer_run: run,
      repo: repo
    } do
      {:ok, _saved} =
        Pipeline.create_diff_comment(scope, task, %{
          path: "shipped.ex",
          line_kind: :added,
          line: 1,
          line_text: "committed",
          filter: :branch,
          body: "Say what was committed."
        })

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      File.write!(Path.join(repo, "shipped.ex"), "rewritten\n")
      send(view.pid, {:run_events, run.id, []})
      _settled = render(view)
      _settled = render(view)

      assert has_element?(
               view,
               "#diff-file-shipped-ex [data-qa='diff_comments_lifted']",
               "1 comment is on a line that has changed."
             )

      assert has_element?(view, "#diff-file-shipped-ex [data-qa='diff_comment_changed']", "Line changed")
      assert has_element?(view, "#diff-file-shipped-ex [data-qa='diff_comment_quote']", "committed")
      assert has_element?(view, "#send-diff-comments", "Send 1 comment")

      test_pid = self()

      expect(Tools, :start_os_process, fn spawned, argv ->
        send(test_pid, {:turn, argv})
        {:ok, %OsProcess{run: spawned}}
      end)

      view |> element("#send-diff-comments") |> render_click()

      assert_receive {:turn, argv}, 5_000
      assert Enum.join(argv, " ") =~ "shipped.ex, line 1\n+ committed\nSay what was committed."
    end

    test "a removed comment is not sent, and with none left Send does nothing", %{
      conn: conn,
      task: task,
      scope: scope,
      engineer_run: run
    } do
      comment = %{path: "shipped.ex", line_kind: :added, line: 1, line_text: "committed", filter: :branch}
      {:ok, kept} = Pipeline.create_diff_comment(scope, task, Map.put(comment, :body, "Keep this one."))
      {:ok, dropped} = Pipeline.create_diff_comment(scope, task, Map.put(comment, :body, "Drop this one."))

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      view |> element("[data-qa='diff_comment_remove'][phx-value-id='#{dropped.id}']") |> render_click()
      refute has_element?(view, "[data-qa='diff_comment']", "Drop this one.")
      assert has_element?(view, "#send-diff-comments", "Send 1 comment")

      # A click from a page drawn before the removal names a comment that is gone.
      view |> with_target("#engineer-stage") |> render_click("remove_diff_comment", %{"id" => dropped.id})

      view |> element("[data-qa='diff_comment_remove'][phx-value-id='#{kept.id}']") |> render_click()
      refute has_element?(view, "[data-qa='diff_comment']")
      refute has_element?(view, "#send-diff-comments")

      view |> with_target("#engineer-stage") |> render_click("send_diff_comments", %{})
      refute has_element?(view, "#engineer-error")
      assert Pipeline.list_run_events(run) == []
    end

    test "comments an engineer with no conversation cannot take are kept, and the pane says why", %{
      conn: conn,
      task: task,
      scope: scope,
      engineer_run: run
    } do
      {:ok, _forgotten} = Pipeline.update_run(run, %{conversation_id: nil})

      {:ok, _saved} =
        Pipeline.create_diff_comment(scope, task, %{
          path: "shipped.ex",
          line_kind: :added,
          line: 1,
          line_text: "committed",
          filter: :branch,
          body: "Say what was committed."
        })

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      view |> element("#send-diff-comments") |> render_click()

      assert has_element?(view, "#engineer-error", "The engineer has no conversation to send these to yet.")
      assert has_element?(view, "[data-qa='diff_comment']", "Not sent")
      refute has_element?(view, "[data-qa='diff_comment']", "Sent")
      assert has_element?(view, "#send-diff-comments", "Send 1 comment")

      assert {:ok, again, _html} = live(conn, ~p"/tasks/#{task.id}")
      assert has_element?(again, "[data-qa='diff_comment']", "Not sent")
    end

    test "the comment being written can be put away, and is not saved blank", %{conn: conn, task: task} do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      stage = with_target(view, "#engineer-stage")
      open = %{"path" => "shipped.ex", "kind" => "added", "old_line" => "", "new_line" => "1"}

      render_click(stage, "open_diff_comment", open)
      view |> form("[data-qa='diff_comment_form']", %{"body" => "Half a thought"}) |> render_change()
      assert has_element?(view, "[data-qa='diff_comment_body']", "Half a thought")

      view |> form("[data-qa='diff_comment_form']", %{"body" => "   "}) |> render_submit()
      assert has_element?(view, "[data-qa='diff_comment_form']")
      refute has_element?(view, "[data-qa='diff_comment']")

      view |> element("[data-qa='diff_comment_cancel']") |> render_click()
      refute has_element?(view, "[data-qa='diff_comment_form']")

      # A line that is not drawn, or a number that is not one, opens nothing.
      render_click(stage, "open_diff_comment", %{open | "new_line" => "40"})
      render_click(stage, "open_diff_comment", %{open | "new_line" => ""})
      refute has_element?(view, "[data-qa='diff_comment_form']")

      # A save from a page drawn before the composer closed has nothing to save.
      render_change(stage, "change_diff_comment", %{"body" => "Too late."})
      render_submit(stage, "save_diff_comment", %{"body" => "Too late."})
      refute has_element?(view, "[data-qa='diff_comment']")

      render_click(stage, "open_diff_comment", open)
      view |> element("#diff-filter-uncommitted") |> render_click()
      view |> element("#diff-filter-branch") |> render_click()
      refute has_element?(view, "[data-qa='diff_comment_form']")
    end

    # A box patched in place from one line to the next keeps the focus on the "+"
    # that moved it, and two files briefly holding one id is a clash in the page.
    test "the comment box opened on another line is a new one, named for its file and line", %{
      conn: conn,
      task: task,
      repo: repo
    } do
      File.write!(Path.join(repo, "tracked.txt"), "two\nthree\n")

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      stage = with_target(view, "#engineer-stage")

      render_click(stage, "open_diff_comment", %{
        "path" => "tracked.txt",
        "kind" => "added",
        "old_line" => "",
        "new_line" => "1"
      })

      assert has_element?(view, "#diff-comment-form-tracked-txt-added-1 #diff-comment-body-tracked-txt-added-1")

      render_click(stage, "open_diff_comment", %{
        "path" => "tracked.txt",
        "kind" => "added",
        "old_line" => "",
        "new_line" => "2"
      })

      assert has_element?(view, "#diff-comment-form-tracked-txt-added-2 #diff-comment-body-tracked-txt-added-2")
      refute has_element?(view, "#diff-comment-form-tracked-txt-added-1")

      render_click(stage, "open_diff_comment", %{
        "path" => "shipped.ex",
        "kind" => "added",
        "old_line" => "",
        "new_line" => "1"
      })

      assert has_element?(view, "#diff-comment-form-shipped-ex-added-1")
      assert [_one] = view |> render() |> Floki.parse_fragment!() |> Floki.find("[data-qa='diff_comment_form']")
    end

    test "Escape puts the comment being written away", %{conn: conn, task: task} do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      view
      |> with_target("#engineer-stage")
      |> render_click("open_diff_comment", %{
        "path" => "shipped.ex",
        "kind" => "added",
        "old_line" => "",
        "new_line" => "1"
      })

      view |> element("[data-qa='diff_comment_body']") |> render_keydown(%{"key" => "Escape"})

      refute has_element?(view, "[data-qa='diff_comment_form']")
    end

    # Send sends what is in the database, so every tab the person has open has to
    # show and count exactly that.
    test "a comment saved, removed or sent in another tab shows here as it is", %{
      conn: conn,
      task: task,
      scope: scope
    } do
      assert {:ok, here, _html} = live(conn, ~p"/tasks/#{task.id}")
      assert {:ok, there, _html} = live(conn, ~p"/tasks/#{task.id}")
      open = %{"path" => "shipped.ex", "kind" => "added", "old_line" => "", "new_line" => "1"}

      for body <- ["Written in the other tab.", "Thought better of it."] do
        there |> with_target("#engineer-stage") |> render_click("open_diff_comment", open)
        there |> form("[data-qa='diff_comment_form']", %{"body" => body}) |> render_submit()
      end

      # The page hears of it and forwards to the stage, each on a turn of its own.
      _settled = render(here)
      _settled = render(here)
      assert has_element?(here, "[data-qa='diff_comment']", "Written in the other tab.")
      assert has_element?(here, "#send-diff-comments", "Send 2 comments")

      [_kept, dropped] = Pipeline.list_diff_comments(scope, task)
      there |> element("[data-qa='diff_comment_remove'][phx-value-id='#{dropped.id}']") |> render_click()

      _settled = render(here)
      _settled = render(here)
      refute has_element?(here, "[data-qa='diff_comment']", "Thought better of it.")
      assert has_element?(here, "#send-diff-comments", "Send 1 comment")

      stub(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)
      there |> element("#send-diff-comments") |> render_click()

      _settled = render(here)
      _settled = render(here)
      assert has_element?(here, "[data-qa='diff_comment']", "Sent")
      refute has_element?(here, "#send-diff-comments")

      # This tab drew the comment before it was sent, so its Send and Remove are stale.
      here |> with_target("#engineer-stage") |> render_click("send_diff_comments", %{})
      here |> with_target("#engineer-stage") |> render_click("remove_diff_comment", %{"id" => dropped.id})
      refute has_element?(here, "#engineer-error")
      assert [%{status: :sent}] = Pipeline.list_diff_comments(scope, task)
    end

    test "resolving a sent comment folds it in every tab, and unresolving sends nothing", %{
      conn: conn,
      task: task,
      scope: scope,
      engineer_run: run,
      repo: repo
    } do
      {:ok, %{id: id}} =
        Pipeline.create_diff_comment(scope, task, %{
          path: "shipped.ex",
          line_kind: :added,
          line: 1,
          line_text: "committed",
          filter: :branch,
          body: "Say what was committed."
        })

      stub(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)
      {:ok, _delivery, _run} = Pipeline.send_diff_comments(scope, run)
      events = Pipeline.list_run_events(run)

      assert {:ok, here, _html} = live(conn, ~p"/tasks/#{task.id}")
      assert {:ok, there, _html} = live(conn, ~p"/tasks/#{task.id}")

      refute has_element?(here, "#diff-comment-#{id} [data-qa='diff_comment_remove']")
      here |> element("#diff-comment-#{id} [data-qa='diff_comment_resolve']") |> render_click()

      assert has_element?(here, "#diff-comment-#{id}[aria-expanded='false']", "Resolved")
      refute has_element?(here, "[data-qa='diff_comment_unresolve']")
      _settled = render(there)
      _settled = render(there)
      assert has_element?(there, "#diff-comment-#{id}[aria-expanded='false']", "Resolved")

      # A second click from a tab drawn before the first is a harmless repeat.
      there |> with_target("#engineer-stage") |> render_click("resolve_diff_comment", %{"id" => id, "resolved" => "true"})
      assert has_element?(there, "#diff-comment-#{id}[aria-expanded='false']")

      here |> element("#diff-comment-#{id}") |> render_click()
      assert has_element?(here, "#diff-comment-#{id}", "Say what was committed.")
      assert has_element?(here, "#diff-comment-#{id} [data-qa='diff_comment_unresolve']")
      refute has_element?(there, "#diff-comment-#{id} [data-qa='diff_comment_unresolve']")

      here |> element("#diff-comment-#{id} [data-qa='diff_comment_fold']") |> render_click()
      assert has_element?(here, "#diff-comment-#{id}[aria-expanded='false']")

      assert {:ok, again, _html} = live(conn, ~p"/tasks/#{task.id}")
      assert has_element?(again, "#diff-comment-#{id}[aria-expanded='false']", "Resolved")

      # Lifted once the engineer rewrites the line, it quotes the line when opened.
      File.write!(Path.join(repo, "shipped.ex"), "rewritten\n")
      assert {:ok, lifted, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(
               lifted,
               "#diff-file-shipped-ex [data-qa='diff_comments_lifted'] #diff-comment-#{id}",
               "Line changed"
             )

      lifted |> element("#diff-comment-#{id}") |> render_click()
      assert has_element?(lifted, "#diff-comment-#{id} [data-qa='diff_comment_quote']", "committed")

      lifted |> element("#diff-comment-#{id} [data-qa='diff_comment_unresolve']") |> render_click()
      assert has_element?(lifted, "#diff-comment-#{id}", "Sent")
      assert has_element?(lifted, "#diff-comment-#{id} [data-qa='diff_comment_resolve']")
      _settled = render(here)
      _settled = render(here)
      assert has_element?(here, "#diff-comment-#{id} [data-qa='diff_comment_resolve']")
      refute has_element?(here, "#send-diff-comments")
      refute has_element?(lifted, "#send-diff-comments")
      assert Pipeline.list_run_events(run) == events
    end

    test "a sent comment whose line the engineer rewrote is lifted, and stays so after a reload", %{
      conn: conn,
      task: task,
      scope: scope,
      engineer_run: run,
      repo: repo
    } do
      {:ok, %{id: id}} =
        Pipeline.create_diff_comment(scope, task, %{
          path: "shipped.ex",
          line_kind: :added,
          line: 1,
          line_text: "committed",
          filter: :branch,
          body: "Say what was committed."
        })

      stub(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)
      {:ok, _delivery, _run} = Pipeline.send_diff_comments(scope, run)

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      File.write!(Path.join(repo, "shipped.ex"), "rewritten\n")
      send(view.pid, {:run_events, run.id, []})
      _settled = render(view)
      _settled = render(view)

      for page <- [view, elem(live(conn, ~p"/tasks/#{task.id}"), 1)] do
        assert has_element?(page, "#diff-file-shipped-ex [data-qa='diff_comments_lifted'] #diff-comment-#{id}", "Sent")
        assert has_element?(page, "#diff-comment-#{id} [data-qa='diff_comment_changed']", "Line changed")
        assert has_element?(page, "#diff-comment-#{id} [data-qa='diff_comment_quote']", "committed")
        refute has_element?(page, "[data-qa='diff_comments_lifted']", "on a line that has changed")
      end
    end

    test "an unsent comment cannot be resolved", %{conn: conn, task: task, scope: scope} do
      {:ok, %{id: id}} =
        Pipeline.create_diff_comment(scope, task, %{
          path: "shipped.ex",
          line_kind: :added,
          line: 1,
          line_text: "committed",
          filter: :branch,
          body: "Say what was committed."
        })

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      assert has_element?(view, "#diff-comment-#{id} [data-qa='diff_comment_remove']")
      refute has_element?(view, "#diff-comment-#{id} [data-qa='diff_comment_resolve']")

      view |> with_target("#engineer-stage") |> render_click("resolve_diff_comment", %{"id" => id, "resolved" => "true"})

      view
      |> with_target("#engineer-stage")
      |> render_click("resolve_diff_comment", %{"id" => "dcm_gone", "resolved" => "true"})

      assert has_element?(view, "#diff-comment-#{id}", "Not sent")
    end

    test "the comments list beside the diff jumps to a comment, unfolding what hides it", %{
      conn: conn,
      task: task,
      scope: scope,
      engineer_run: run
    } do
      {:ok, %{id: id}} =
        Pipeline.create_diff_comment(scope, task, %{
          path: "shipped.ex",
          line_kind: :added,
          line: 1,
          line_text: "committed",
          filter: :branch,
          body: "Say what was committed."
        })

      stub(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)
      {:ok, _delivery, _run} = Pipeline.send_diff_comments(scope, run)
      [sent] = Pipeline.list_diff_comments(scope, task)
      {:ok, _resolved} = Pipeline.set_diff_comment_resolved(scope, sent, true)

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      view |> element("#diff-header-shipped-ex [data-qa='diff_collapse_toggle']") |> render_click()
      view |> form("#diff-file-filter", %{"query" => "nothing-like-this"}) |> render_change()
      refute has_element?(view, "#diff-comment-#{id}")

      view |> element("#diff-list-comments", "Comments 1") |> render_click()
      refute has_element?(view, "[data-qa='diff-file-row']")
      assert has_element?(view, "[data-qa='diff_comment_group_resolved']", "Resolved 1")

      view |> element("[data-qa='diff_comment_list_jump'][phx-value-id='#{id}']") |> render_click()

      assert_push_event(view, "diff:scroll_to", %{id: "diff-comment-" <> ^id})
      assert has_element?(view, "#diff-comment-#{id} [data-qa='diff_comment_unresolve']")
      assert has_element?(view, "[data-qa='diff_comment_list_row'][aria-current='true']", "Say what was committed.")

      view |> element("[data-qa='diff_comment_list_resolve'][phx-value-id='#{id}']") |> render_click()
      assert has_element?(view, "[data-qa='diff_comment_group_sent']", "Sent 1")
      assert has_element?(view, "#diff-comment-#{id} [data-qa='diff_comment_resolve']")

      # A row from a page drawn before the comment went is a jump to nowhere.
      view |> with_target("#engineer-stage") |> render_click("select_diff_comment", %{"id" => "dcm_gone"})

      view |> element("#diff-list-files") |> render_click()
      assert has_element?(view, "[data-qa='diff-file-row']", "shipped.ex")
    end
  end

  describe "the conversation, which the page hosts and feeds" do
    setup %{project: project, task: task, run: run} do
      {:ok, other_role} = Roles.get_role(project_id: project.id, stage: :engineer)

      {:ok, other_run} =
        Pipeline.create_run(%{
          task_id: task.id,
          role_id: other_role.id,
          status: :finished,
          conversation_id: "sess_engineer",
          started_at: ~U[2026-09-09 09:00:00Z]
        })

      {:ok, working} =
        Pipeline.update_run(run, %{
          status: :running,
          stage_outcome: :in_progress,
          conversation_id: "sess_product",
          started_at: ~U[2026-09-09 10:00:00Z]
        })

      Pipeline.append_run_events(working.id, nil, ["[tool read_file] lib/rail.ex"])

      {:ok, task} = Pipeline.update_task(task, %{worktree_path: create_temp_git_repo()})

      %{task: task, run: working, other_role: other_role, other_run: other_run}
    end

    test "switches to another role on request, and stays there while the stage does", %{
      conn: conn,
      task: task,
      other_role: other_role
    } do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "#task-tab-#{other_role.id}")

      view |> element("#task-tab-#{other_role.id}") |> render_click()
      assert has_element?(view, "#metadata-run-conversation-id", "sess_engineer")

      send(view.pid, :task_changed)
      assert has_element?(view, "#metadata-run-conversation-id", "sess_engineer")
    end

    # One scroller serves every tab, so the scroll hook tells another run from a patch by its id.
    test "the conversation's scrollers name the run they show", %{
      conn: conn,
      task: task,
      run: run,
      other_role: other_role,
      other_run: other_run
    } do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      assert has_element?(view, "#chat-messages[data-run-id='#{run.id}']")

      view |> element("#task-tab-#{other_role.id}") |> render_click()
      assert has_element?(view, "#chat-messages[data-run-id='#{other_run.id}']")

      view |> element("#toggle-raw-log") |> render_click()
      assert has_element?(view, "#raw-log-container[data-run-id='#{other_run.id}']")
    end

    test "moving to the next stage moves the conversation to that stage's run", %{conn: conn, task: task} do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      assert has_element?(view, "#metadata-run-conversation-id", "sess_product")

      {:ok, _moved} = Pipeline.update_task(task, %{stage: :engineer})
      send(view.pid, :task_changed)

      assert has_element?(view, "#metadata-run-conversation-id", "sess_engineer")
    end

    test "log lines for another run on the task stay out of the one being read", %{
      conn: conn,
      task: task,
      other_run: other_run
    } do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      send(view.pid, {:run_events, other_run.id, [%{id: "evt_designer", line: "The designer's line"}]})

      _settled = render(view)
      refute render(view) =~ "The designer&#39;s line"
      refute render(view) =~ "The designer's line"
    end

    # Stacked under the stage, a conversation with no height limit grows to its full
    # length and pushes the composer off the bottom of the screen.
    test "stacked below the desktop breakpoint, the conversation takes a bounded share and scrolls itself", %{
      conn: conn,
      task: task
    } do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert [class] =
               view |> render() |> Floki.parse_fragment!() |> Floki.attribute("#task-conversation-column", "class")

      classes = String.split(class)
      assert "flex-1" in classes
      assert "lg:flex-none" in classes
      refute "shrink-0" in classes
    end

    test "stopping with nothing queued leaves the composer as it was", %{conn: conn, task: task, run: run} do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      view |> element("#stop-run") |> render_click()

      assert has_element?(view, "#chat-input")
      refute has_element?(view, "#chat-input", "Please")
      assert %Run{status: :finished} = Repo.reload!(run)
    end

    test "stopping puts the undelivered message ahead of the draft", %{conn: conn, task: task, run: run} do
      {:ok, _queued} = Pipeline.update_run(run, %{pending_chat: "Please add a test"})

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      view |> element("#chat-composer-form") |> render_change(%{"message" => "Also this"})
      view |> element("#cancel-queued-message") |> render_click()

      assert render(view) =~ "Please add a test\n\nAlso this"
    end

    test "each tool step carries an icon for its kind", %{conn: conn, task: task, run: run} do
      Pipeline.append_run_events(run.id, nil, [
        "[tool] Edit lib/rail.ex",
        "[tool] Bash mix test",
        "[tool] Grep defmodule",
        "[tool] WebFetch https://example.com",
        "[tool] Task explore",
        "[tool] TodoWrite plan",
        "[tool] Mystery thing",
        "[tool] Read",
        "[tool unterminated",
        "[tool error] It broke"
      ])

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      view |> element("[data-qa='activity-tile'] button") |> render_click()

      html = view |> element("[data-qa='activity-content']") |> render()

      for icon <- [
            "pi-file-text",
            "pi-pencil-simple",
            "pi-terminal-window",
            "pi-magnifying-glass",
            "pi-globe",
            "pi-robot",
            "pi-list-checks",
            "pi-wrench",
            "pi-warning-circle"
          ] do
        assert html =~ icon
      end

      assert has_element?(view, "[data-qa='activity-step']", "[tool unterminated")
      assert html =~ ">It broke</p>"
    end

    test "a line already loaded is not appended again when its broadcast arrives", %{
      conn: conn,
      task: task,
      run: run
    } do
      entries = Pipeline.append_run_events(run.id, nil, ["[human] it is connected now"])

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      send(view.pid, {:run_events, run.id, entries})

      bubble = view |> element("[data-qa='human-bubble']") |> render()
      assert length(String.split(bubble, "it is connected now")) == 2
    end

    test "the raw log colors each line by its source", %{conn: conn, task: task, run: run} do
      Pipeline.append_run_events(run.id, nil, ["[error] bad", "[human] hi", "[rail] note", "plain words"])

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      view |> element("#toggle-raw-log") |> render_click()

      assert has_element?(view, "[data-qa='raw-log-line'].text-red-400", "[error] bad")
      assert has_element?(view, "[data-qa='raw-log-line'].text-cyan-300", "[tool read_file]")
      assert has_element?(view, "[data-qa='raw-log-line'].text-amber-300", "[human] hi")
      assert has_element?(view, "[data-qa='raw-log-line'].text-green-400", "[rail] note")
      assert has_element?(view, "[data-qa='raw-log-line'].text-zinc-300", "plain words")
    end

    test "the raw log takes whatever height its column leaves", %{conn: conn, task: task} do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      view |> element("#toggle-raw-log") |> render_click()

      assert [class] =
               view |> render() |> Floki.parse_fragment!() |> Floki.attribute("#raw-log-container", "class")

      assert "min-h-0" in String.split(class)
      refute "min-h-[400px]" in String.split(class)
    end

    test "the raw log wraps long lines and never scrolls sideways", %{conn: conn, task: task, run: run} do
      Pipeline.append_run_events(run.id, nil, [
        ~s({"type":"assistant","message":{"content":[{"type":"text","text":"#{String.duplicate("x", 400)}"}]}})
      ])

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      view |> element("#toggle-raw-log") |> render_click()

      doc = view |> render() |> Floki.parse_fragment!()
      assert [class] = Floki.attribute(doc, "#raw-log-container", "class")
      assert ["overflow-y-auto", "overflow-x-hidden"] -- String.split(class) == []

      assert [_first | _rest] = line_classes = Floki.attribute(doc, "[data-qa='raw-log-line']", "class")
      assert Enum.all?(line_classes, &("wrap-break-word" in String.split(&1)))

      assert "[tool read_file] lib/rail.ex" in (doc |> Floki.find("[data-qa='raw-log-line']") |> Enum.map(&Floki.text/1))
    end

    test "shows the raw log on request, and the chat again after", %{conn: conn, task: task} do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      view |> element("#toggle-raw-log") |> render_click()
      assert has_element?(view, "[data-qa='raw-log-line']")

      view |> element("#toggle-raw-log") |> render_click()
      assert has_element?(view, "[data-qa='chat-pane']")
    end

    test "opens and closes the tool activity behind a turn", %{conn: conn, task: task} do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "[data-qa='activity-tile']")
      refute has_element?(view, "[data-qa='activity-content']")

      view |> element("[data-qa='activity-tile'] button") |> render_click()
      assert has_element?(view, "[data-qa='activity-content']")
      assert has_element?(view, "[data-qa='activity-step']", "read_file")
      assert has_element?(view, "[data-qa='activity-step']", "lib/rail.ex")

      view |> element("[data-qa='activity-tile'] button") |> render_click()
      refute has_element?(view, "[data-qa='activity-content']")
    end

    test "a refused save opens as a red step under the tool's name, carrying the sentence", %{
      conn: conn,
      task: task,
      run: run
    } do
      sentence = ~s(Refused, nothing saved. line: must be a whole number, got "88-94".)
      _logged = Pipeline.append_run_events(run.id, nil, ["[tool error mcp__rail__save_finding] #{sentence}"])

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      view |> element("[data-qa='activity-tile']:last-of-type button") |> render_click()

      assert has_element?(view, "[data-qa='activity-step'].border-l-red-500 .font-medium", "save_finding")
      assert has_element?(view, "[data-qa='activity-step'].border-l-red-500 p", "must be a whole number")
      refute has_element?(view, "[data-qa='activity-step']", "mcp__rail__")
    end

    test "a message typed while the agent works waits on its run", %{conn: conn, task: task, run: run} do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      view |> element("#chat-composer-form") |> render_change(%{"message" => "Please add a test"})
      view |> element("#chat-composer-form") |> render_submit(%{"message" => "Please add a test"})

      assert has_element?(view, "#queued-banner", "Please add a test")
      assert %Run{pending_chat: "Please add a test"} = Repo.reload!(run)
    end

    test "stopping hands the undelivered message back to the composer", %{conn: conn, task: task, run: run} do
      {:ok, _queued} = Pipeline.update_run(run, %{pending_chat: "Please add a test"})

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      view |> element("#cancel-queued-message") |> render_click()

      assert has_element?(view, "#chat-input", "Please add a test")
      assert %Run{pending_chat: nil, status: :finished} = Repo.reload!(run)
    end

    test "send now cuts the turn short and delivers what was queued", %{conn: conn, task: task, run: run} do
      {:ok, _queued} = Pipeline.update_run(run, %{pending_chat: "Please add a test"})

      stub(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      view |> element("#send-queued-now") |> render_click()

      assert has_element?(view, "#conversation-tab-root")
    end

    test "an empty message is not a message", %{conn: conn, task: task, run: run} do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      view |> element("#chat-composer-form") |> render_submit(%{"message" => "   "})

      assert %Run{pending_chat: nil} = Repo.reload!(run)
    end

    test "new log lines reach the conversation while it is open", %{conn: conn, task: task, run: run} do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      send(view.pid, {:run_events, run.id, [%{id: UXID.generate!(), line: "A fresh line of output"}]})

      # The page forwards to the component, which renders on its own turn.
      _settled = render(view)
      assert render(view) =~ "A fresh line of output"
    end

    # The turns are read once and again only when a turn nobody has seen shows
    # up, so a second batch of lines for a turn already on screen is not another
    # query.
    test "more lines for a turn already on screen are not another read", %{conn: conn, task: task, run: run} do
      os_process =
        %OsProcess{}
        |> OsProcess.changeset(%{
          run_id: run.id,
          task_id: task.id,
          stream_path: "/tmp/#{run.id}.ndjson",
          status: :finished,
          started_at: DateTime.utc_now()
        })
        |> Repo.insert!()

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      for line <- ["the first thing it said", "the second thing it said"] do
        Pipeline.append_run_events(run.id, os_process.id, [line])
        _settled = render(view)
      end

      assert render(view) =~ "the second thing it said"
    end

    test "log lines for a run the page is not following are ignored", %{conn: conn, task: task} do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      send(view.pid, {:run_events, "run_somebody_else", [%{line: "Not for this page"}]})

      refute render(view) =~ "Not for this page"
    end

    test "a queued message going out shows the run working", %{conn: conn, task: task, run: run} do
      {:ok, queued} = Pipeline.update_run(run, %{status: :finished, pending_chat: "One more thing"})
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      assert has_element?(view, "#queued-banner")

      {:ok, _running} = Pipeline.update_run(queued, %{status: :running, pending_chat: nil})
      send(view.pid, {:run_changed, run.id})

      refute has_element?(view, "#queued-banner")
      assert has_element?(view, "#thinking-banner")
    end

    test "an OS process finishing refreshes the page", %{conn: conn, task: task, run: run} do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      {:ok, _failed} = Pipeline.update_run(run, %{status: :finished, error: "It fell over."})
      send(view.pid, {:os_process_finished, run, %{}})

      assert has_element?(view, "[data-qa='task_error_card']", "It fell over.")
    end

    test "a turn finishing refreshes the issue tab too", %{conn: conn, task: task, run: run} do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      view |> element("#task-tab-issue") |> render_click()

      {:ok, _failed} = Pipeline.update_run(run, %{status: :finished, error: "It fell over."})
      send(view.pid, {:os_process_finished, run, %{}})

      assert has_element?(view, "[data-qa='issue-page']")
      assert has_element?(view, "#task-tab-#{run.role_id}", "failed")
    end

    test "a turn finishing re-reads the ticket the agent may have changed", %{conn: conn, task: task, run: run} do
      ticket_path = Path.join([task.scratch_path, "tickets", "TLV-1.md"])
      File.write!(ticket_path, "# A ticket\n\nThe first draft.")

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      view |> element("#plan-item-ticket") |> render_click()
      assert has_element?(view, "[data-qa='plan_ticket']", "The first draft.")

      File.write!(ticket_path, "# A ticket\n\nThe revised draft.")
      send(view.pid, {:os_process_finished, run, %{}})

      # The page forwards to the component, which renders on its own turn.
      _settled = render(view)
      assert has_element?(view, "[data-qa='plan_ticket']", "The revised draft.")
    end
  end

  describe "the review stage" do
    setup %{project: project, task: task} do
      {:ok, role} = Roles.get_role(project_id: project.id, stage: :review_lead)
      {:ok, engineer_role} = Roles.get_role(project_id: project.id, stage: :engineer)
      {:ok, task} = Pipeline.update_task(task, %{stage: :review, worktree_path: create_temp_git_repo()})

      {:ok, _engineer_run} =
        Pipeline.create_run(%{
          task_id: task.id,
          role_id: engineer_role.id,
          status: :finished,
          stage_outcome: :done,
          conversation_id: "sess_review_stage_engineer",
          started_at: DateTime.utc_now()
        })

      {:ok, review_run} =
        Pipeline.create_run(%{
          task_id: task.id,
          role_id: role.id,
          status: :finished,
          stage_outcome: :done,
          conversation_id: "sess_review_stage",
          started_at: DateTime.utc_now()
        })

      # A code finding as the lead raises one; a test changes only the fields it is about.
      code = %{
        key: "unhandled-nil",
        kind: :code,
        raised_by: :code_reviewer,
        title: "Nil is not handled",
        problem: "The clause assumes a map.",
        file: "lib/rail/example.ex",
        line: 12,
        fix: "Match the empty map first.",
        why: "A task with no worktree crashes the page.",
        rule: "Every clause handles a missing map.",
        severity: :blocker,
        recommendation: :fix,
        places: [%{file: "lib/rail/example.ex", line: 12, label: "handle/1"}],
        evidence: [%{name: "The clause", kind: :code, file: "lib/rail/example.ex", line: 12}]
      }

      %{task: task, role: role, engineer_role: engineer_role, review_run: review_run, code: code}
    end

    test "one Review tab, the lead's, counts the findings to rule beside its questions, and none while it runs", %{
      conn: conn,
      task: task,
      role: role,
      review_run: run,
      code: code
    } do
      for key <- ["a-blocker", "a-nit"], do: {:ok, _saved} = Pipeline.save_finding(task, %{code | key: key})
      {:ok, _pass} = Pipeline.save_review(task)
      {:ok, blocked} = Pipeline.update_run(run, %{status: :blocked_on_input, stage_outcome: :in_progress})

      {:ok, _asked} =
        blocked |> Repo.preload(task: :issue) |> Pipeline.register_question(%DetectedQuestion{prompt: "Why?"})

      assert {:ok, view, html} = live(conn, ~p"/tasks/#{task.id}")

      review_tab = "task-tab-#{role.id}"

      assert [_issue, _plan, _engineer, ^review_tab] =
               html |> Floki.parse_document!() |> Floki.find("[role='tab']") |> Floki.attribute("id")

      assert has_element?(view, "#task-tab-#{role.id}[aria-selected='true']", role.name)
      assert has_element?(view, "#task-tab-#{role.id} [data-qa='task-tab-badge']", "3")

      {:ok, _running} = Pipeline.update_run(blocked, %{status: :running})
      send(view.pid, :task_changed)

      assert has_element?(view, "#task-tab-#{role.id} [data-qa='task-tab-badge']", "1")
    end

    test "ruling the last finding to rule takes the count off the Review tab", %{
      conn: conn,
      task: task,
      role: role,
      code: code
    } do
      {:ok, _saved} = Pipeline.save_finding(task, code)
      {:ok, _pass} = Pipeline.save_review(task)

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      assert has_element?(view, "#task-tab-#{role.id} [data-qa='task-tab-badge']", "1")

      view |> element("#decide-skip-unhandled-nil") |> render_click()

      # The ruling's broadcast reaches the page after the click returns.
      _settled = render(view)
      refute has_element?(view, "#task-tab-#{role.id} [data-qa='task-tab-badge']")
    end

    test "the header says whether Review is running, failed, waiting on the findings or ready to merge", %{
      conn: conn,
      task: task,
      review_run: run
    } do
      {:ok, running} = Pipeline.update_run(run, %{status: :running, stage_outcome: :in_progress})
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      assert has_element?(view, "[data-qa='task_status_chip']", "Review running")

      {:ok, failed} = Pipeline.update_run(running, %{status: :finished, error: "The lead gave up."})
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      assert has_element?(view, "[data-qa='task_status_chip']", "Review failed")

      {:ok, done} = Pipeline.update_run(failed, %{stage_outcome: :done, error: nil})
      {:ok, _pass} = Pipeline.save_review(task)
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      assert has_element?(view, "[data-qa='task_status_chip']", "Review the findings")

      {:ok, _finished} = Pipeline.start_fix_round(done)
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      assert has_element?(view, "[data-qa='task_status_chip']", "Ready to merge")
    end

    test "working in the question card does not read the findings again", %{conn: conn, task: task, review_run: run} do
      {:ok, blocked} = Pipeline.update_run(run, %{status: :blocked_on_input, stage_outcome: :in_progress})
      blocked = Repo.preload(blocked, task: :issue)

      {:ok, _first} =
        Pipeline.register_question(blocked, %DetectedQuestion{prompt: "Fix it here?", options: ["Yes", "No"]})

      {:ok, _second} = Pipeline.register_question(blocked, %DetectedQuestion{prompt: "Who owns it?"})

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      reject(&Pipeline.list_findings/1)

      for typed <- ["Y", "Ye", "Yes", "Yes, in this branch"] do
        view |> form("#answer-question-form", %{"answer" => typed}) |> render_change()
        assert has_element?(view, "#answer-textarea", typed)
      end

      view |> element("#question-option-1") |> render_click()
      assert has_element?(view, "#question-option-1.bg-blue-100")

      view |> element("#question-tab-1") |> render_click()
      assert has_element?(view, "#question-prompt", "Who owns it?")
    end

    test "the list puts the worst finding first, each with where it is, and opens it", %{
      conn: conn,
      task: task,
      code: code
    } do
      {:ok, _nit} = Pipeline.save_finding(task, %{code | key: "naming-nit", title: "Poor variable name", severity: :nit})
      {:ok, _blocker} = Pipeline.save_finding(task, code)

      {:ok, _screen} =
        Pipeline.save_finding(task, %{
          key: "send-twice",
          kind: :screen,
          raised_by: :explorer,
          title: "Send stays enabled",
          problem: "A second click sends the same comments twice.",
          screen: "Engineer tab, Diff toolbar",
          steps: ["Click Send", "Click it again"],
          fix: "Disable Send until the server answers.",
          why: "Two runs for one round.",
          rule: "A round is sent once.",
          severity: :major,
          recommendation: :fix,
          places: [%{screen: "Engineer tab, Diff toolbar", label: "Send button"}],
          evidence: [%{name: "deliveries", kind: :log, text: "2 deliveries for one round"}]
        })

      {:ok, _pass} = Pipeline.save_review(task)

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert ["finding-unhandled-nil", "finding-send-twice", "finding-naming-nit"] =
               view |> render() |> Floki.parse_fragment!() |> Floki.attribute("[data-qa='review_finding']", "id")

      assert has_element?(view, "#finding-unhandled-nil", "lib/rail/example.ex:12")
      assert has_element?(view, "#finding-send-twice", "Engineer tab, Diff toolbar")
      assert has_element?(view, "#finding-unhandled-nil[aria-current='true']")
      assert has_element?(view, "[data-qa='review_finding_detail']", "Nil is not handled")
      assert has_element?(view, "[data-qa='finding_position']", "1 of 3")
    end

    test "the reader walks the findings with Previous and Next, without going back to the list", %{
      conn: conn,
      task: task,
      code: code
    } do
      {:ok, _blocker} = Pipeline.save_finding(task, code)
      {:ok, _nit} = Pipeline.save_finding(task, %{code | key: "naming-nit", title: "Poor variable name", severity: :nit})
      {:ok, _pass} = Pipeline.save_review(task)

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      assert has_element?(view, "#finding-previous[disabled]")

      view |> element("#finding-next") |> render_click()

      assert has_element?(view, "[data-qa='review_finding_detail']", "Poor variable name")
      assert has_element?(view, "[data-qa='finding_position']", "2 of 2")
      assert has_element?(view, "#finding-naming-nit[aria-current='true']")
      assert has_element?(view, "#finding-next[disabled]")

      view |> element("#finding-previous") |> render_click()

      assert has_element?(view, "[data-qa='review_finding_detail']", "Nil is not handled")
    end

    # A finding names a line; the change it points at lives on the engineer's tab,
    # so the pane shows the one hunk and links to that file in the whole diff.
    test "a finding shows the change it points at and opens that file in the Engineer tab's diff", %{
      conn: conn,
      task: task,
      engineer_role: engineer_role,
      code: code
    } do
      File.mkdir_p!(Path.join(task.worktree_path, "lib/rail"))
      File.write!(Path.join(task.worktree_path, "lib/rail/example.ex"), Enum.map_join(1..20, "", &"line #{&1}\n"))
      git!(task.worktree_path, ["add", "."])
      git!(task.worktree_path, ["commit", "-m", "before"])
      git!(task.worktree_path, ["update-ref", "refs/remotes/origin/main", "HEAD"])
      git!(task.worktree_path, ["checkout", "-b", "feature"])

      File.write!(
        Path.join(task.worktree_path, "lib/rail/example.ex"),
        Enum.map_join(1..20, "", fn
          12 -> "the line the finding points at\n"
          n -> "line #{n}\n"
        end)
      )

      git!(task.worktree_path, ["add", "."])
      git!(task.worktree_path, ["commit", "-m", "the change under review"])

      {:ok, _saved} = Pipeline.save_finding(task, code)
      {:ok, _pass} = Pipeline.save_review(task)

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "[data-qa='finding_diff']", "lib/rail/example.ex")
      assert has_element?(view, "[data-qa='diff_line_row']", "the line the finding points at")

      assert has_element?(
               view,
               ~s(#finding-open-in-diff[href="/tasks/#{task.id}?tab=#{engineer_role.id}&file=lib%2Frail%2Fexample.ex"]),
               "Open in diff"
             )

      view |> element("#finding-open-in-diff") |> render_click()

      assert_patch(view, ~p"/tasks/#{task.id}?tab=#{engineer_role.id}&file=#{"lib/rail/example.ex"}")
    end

    # Only a window around the line the finding names is shown, so the pane has
    # to say what it left out rather than let the reader take it for the whole change.
    test "a hunk says what it left out", %{conn: conn, task: task, code: code} do
      File.mkdir_p!(Path.join(task.worktree_path, "lib/rail"))
      File.write!(Path.join(task.worktree_path, "lib/rail/example.ex"), Enum.map_join(1..80, "", &"line #{&1}\n"))
      git!(task.worktree_path, ["add", "."])
      git!(task.worktree_path, ["commit", "-m", "before"])
      git!(task.worktree_path, ["update-ref", "refs/remotes/origin/main", "HEAD"])
      git!(task.worktree_path, ["checkout", "-b", "feature"])

      after_change =
        Enum.map_join(1..80, "", fn
          n when n in 8..40 -> "rewritten line #{n}\n"
          70 -> "changed near the bottom\n"
          n -> "line #{n}\n"
        end)

      File.write!(Path.join(task.worktree_path, "lib/rail/example.ex"), after_change)
      git!(task.worktree_path, ["add", "."])
      git!(task.worktree_path, ["commit", "-m", "the change under review"])

      {:ok, _saved} = Pipeline.save_finding(task, %{code | key: "long-hunk", title: "A long change", line: 20})

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "[data-qa='finding_other_hunks']", "more lines")
      assert has_element?(view, "[data-qa='finding_other_hunks']", "1 more other change in this file.")
    end

    # Severity is the first thing a reader takes off the list, so every grade has to be distinguishable.
    test "each severity reads as itself, on its row and in the pane", %{conn: conn, task: task, code: code} do
      for severity <- [:blocker, :major, :minor, :nit],
          do:
            {:ok, _saved} =
              Pipeline.save_finding(task, %{code | key: "a-#{severity}", title: "A #{severity}", severity: severity})

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      for {severity, dot} <- [blocker: "bg-red-500", major: "bg-amber-500", minor: "bg-amber-400", nit: "bg-slate-400"] do
        view |> element("#finding-a-#{severity}") |> render_click()

        assert has_element?(view, "#finding-a-#{severity} > span.#{dot}")
        assert has_element?(view, "#review-finding-detail h2", "A #{severity}")
        assert has_element?(view, "#review-finding-detail span", Atom.to_string(severity))
      end
    end

    # Two people watching the same review both see each finding the moment the
    # lead saves it, and neither can rule on it until the round finishes.
    test "a finding saved mid-round shows in every open tab, with nothing to rule on yet", %{
      conn: conn,
      task: task,
      review_run: run,
      code: code
    } do
      {:ok, _running} = Pipeline.update_run(run, %{status: :running, stage_outcome: :in_progress})

      assert {:ok, one, _html} = live(conn, ~p"/tasks/#{task.id}")
      assert {:ok, two, _html} = live(conn, ~p"/tasks/#{task.id}")
      assert has_element?(one, "#review-no-findings", "Findings appear here as the round saves them.")

      {:ok, _saved} = Pipeline.save_finding(task, code)

      for view <- [one, two] do
        _settled = render(view)
        assert has_element?(view, "#finding-unhandled-nil", "Nil is not handled")
        assert has_element?(view, "[data-qa='review_finding_tally']", "1 so far · rule once round 1 finishes")
        assert has_element?(view, "[data-qa='finding_state']", "Rule on it once the round finishes")
        refute has_element?(view, "[data-qa='review_finding_state']", "Needs your call")
        refute has_element?(view, "[data-qa='decide_fix']")
      end
    end

    test "a finished round that found nothing says so", %{conn: conn, task: task} do
      {:ok, _pass} = Pipeline.save_review(task)

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "#review-no-findings", "No findings.")
      assert has_element?(view, "#start-fix-round", "Finish review")
    end

    # A run that stopped without closing its round and one that found nothing look the
    # same on the list, and only one of them is a review anybody should finish.
    test "a run that stopped without closing its round offers no Finish review", %{
      conn: conn,
      task: task,
      review_run: run
    } do
      {:ok, _stopped} = Pipeline.update_run(run, %{status: :finished, stage_outcome: :in_progress})

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "#review-no-findings", "No findings.")
      refute has_element?(view, "#start-fix-round")
    end

    # A finding is inserted rather than saved, so no broadcast reaches the page and only the turn finishing can.
    test "a turn finishing re-reads the findings it just recorded", %{
      conn: conn,
      task: task,
      review_run: run,
      code: code
    } do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      assert has_element?(view, "#review-no-findings")

      Repo.insert!(Finding.raise_changeset(%Finding{task_id: task.id, round: 1}, code))
      send(view.pid, {:os_process_finished, run, %{}})

      _settled = render(view)
      assert has_element?(view, "[data-qa='review_finding_detail']", "Nil is not handled")
    end

    test "a run started underneath the page holds the ruling", %{
      conn: conn,
      task: task,
      review_run: run,
      code: code
    } do
      {:ok, _saved} = Pipeline.save_finding(task, code)
      {:ok, _pass} = Pipeline.save_review(task)

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      {:ok, _running} = Pipeline.update_run(run, %{status: :running})
      view |> element("#decide-skip-unhandled-nil") |> render_click()

      assert has_element?(view, "#review-error", "Something is still running on this task.")
      assert [%Finding{decision: nil}] = Pipeline.list_findings(task)
    end

    test "a task moved on underneath the page says where it went", %{conn: conn, task: task, code: code} do
      {:ok, _saved} = Pipeline.save_finding(task, code)
      {:ok, _pass} = Pipeline.save_review(task)

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      {:ok, _moved} = Pipeline.update_task(task, %{stage: :merged})
      view |> element("#decide-fix-unhandled-nil") |> render_click()

      assert has_element?(view, "#review-error", "This task is at Merged, not Review.")
    end

    # Clicked in the moment before a save's broadcast lands, the refusal is said.
    test "a finding raised underneath the page holds Start fix round", %{conn: conn, task: task, code: code} do
      {:ok, finding} = Pipeline.save_finding(task, code)
      {:ok, _pass} = Pipeline.save_review(task)
      {:ok, _ruled} = Pipeline.decide_finding(system_scope(), finding, :fix)

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      refute has_element?(view, "#start-fix-round[disabled]")

      Repo.insert!(Finding.raise_changeset(%Finding{task_id: task.id, round: 1}, %{code | key: "raised-late"}))
      view |> element("#start-fix-round") |> render_click()

      assert has_element?(view, "#review-error", "Some findings have no ruling yet.")
    end

    test "ruling on a finding keeps the list in place and reads the next one needing a call", %{
      conn: conn,
      task: task,
      code: code
    } do
      for {key, severity} <- [{"a-blocker", :blocker}, {"a-major", :major}, {"a-nit", :nit}],
          do: {:ok, _saved} = Pipeline.save_finding(task, %{code | key: key, title: key, severity: severity})

      {:ok, _pass} = Pipeline.save_review(task)

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      view |> element("#decide-skip-a-blocker") |> render_click()

      assert ["finding-a-blocker", "finding-a-major", "finding-a-nit"] =
               view |> render() |> Floki.parse_fragment!() |> Floki.attribute("[data-qa='review_finding']", "id")

      assert has_element?(
               view,
               "#finding-a-blocker[data-state='dismissed'] [data-qa='review_finding_state']",
               "Don't fix"
             )

      assert has_element?(view, "#finding-a-major[aria-current='true']")
      assert has_element?(view, "[data-qa='review_finding_detail']", "a-major")
      assert has_element?(view, "[data-qa='finding_position']", "2 of 3")
    end

    test "with nothing needing a call below, the next one is above", %{conn: conn, task: task, code: code} do
      for {key, severity} <- [{"a-blocker", :blocker}, {"a-nit", :nit}],
          do: {:ok, _saved} = Pipeline.save_finding(task, %{code | key: key, title: key, severity: severity})

      {:ok, _pass} = Pipeline.save_review(task)

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      view |> element("#finding-a-nit") |> render_click()
      view |> element("#decide-fix-a-nit") |> render_click()

      assert has_element?(view, "#finding-a-blocker[aria-current='true']")
    end

    test "the last ruling stays where it is and lets the fix round start", %{conn: conn, task: task, code: code} do
      [blocker, _nit] =
        for {key, severity} <- [{"a-blocker", :blocker}, {"a-nit", :nit}] do
          {:ok, saved} = Pipeline.save_finding(task, %{code | key: key, title: key, severity: severity})
          saved
        end

      {:ok, _pass} = Pipeline.save_review(task)
      {:ok, _decided} = Pipeline.decide_finding(system_scope(), blocker, :fix)

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      view |> element("#finding-a-nit") |> render_click()
      view |> element("#decide-skip-a-nit") |> render_click()

      assert has_element?(view, "#finding-a-nit[aria-current='true']")
      refute has_element?(view, "[data-qa='review_finding_state']", "Needs your call")
      assert has_element?(view, "#start-fix-round:not([disabled])", "Start fix round 1")
    end

    test "changing a ruling leaves the reader where they are", %{conn: conn, task: task, code: code} do
      [blocker, _major, _nit] =
        for {key, severity} <- [{"a-blocker", :blocker}, {"a-major", :major}, {"a-nit", :nit}] do
          {:ok, saved} = Pipeline.save_finding(task, %{code | key: key, title: key, severity: severity})
          saved
        end

      {:ok, _pass} = Pipeline.save_review(task)
      {:ok, _decided} = Pipeline.decide_finding(system_scope(), blocker, :fix)

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      view |> element("#decide-skip-a-blocker") |> render_click()

      assert ["finding-a-blocker", "finding-a-major", "finding-a-nit"] =
               view |> render() |> Floki.parse_fragment!() |> Floki.attribute("[data-qa='review_finding']", "id")

      assert has_element?(view, "#finding-a-blocker[aria-current='true'][data-state='dismissed']")
    end

    # A double click's second click lands on the finding just moved to, which nobody has read.
    test "a double click rules only the finding that was read", %{conn: conn, task: task, code: code} do
      for {key, severity} <- [{"a-blocker", :blocker}, {"a-major", :major}, {"a-nit", :nit}],
          do: {:ok, _saved} = Pipeline.save_finding(task, %{code | key: key, title: key, severity: severity})

      {:ok, _pass} = Pipeline.save_review(task)

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      view |> element("#decide-fix-a-blocker") |> render_click()
      view |> element("#decide-fix-a-major") |> render_click()

      assert [%{key: "a-blocker", decision: :fix}, %{key: "a-major", decision: nil}, %{key: "a-nit", decision: nil}] =
               Pipeline.list_findings(task)

      assert has_element?(
               view,
               "#finding-a-major[aria-current='true'] [data-qa='review_finding_state']",
               "Needs your call"
             )
    end

    test "the finding moved to can be ruled on once it has been seen", %{conn: conn, task: task, code: code} do
      for {key, severity} <- [{"a-blocker", :blocker}, {"a-major", :major}],
          do: {:ok, _saved} = Pipeline.save_finding(task, %{code | key: key, title: key, severity: severity})

      {:ok, _pass} = Pipeline.save_review(task)

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      view |> element("#decide-fix-a-blocker") |> render_click()
      Process.sleep(400)
      view |> element("#decide-fix-a-major") |> render_click()

      assert [%{key: "a-blocker", decision: :fix}, %{key: "a-major", decision: :fix}] = Pipeline.list_findings(task)
    end

    test "the row being read keeps itself in view", %{conn: conn, task: task, code: code} do
      for key <- ["a-blocker", "a-nit"], do: {:ok, _saved} = Pipeline.save_finding(task, %{code | key: key})

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert ["CurrentInView", "CurrentInView"] =
               view |> render() |> Floki.parse_fragment!() |> Floki.attribute("[data-qa='review_finding']", "phx-hook")
    end

    # Leaving a suppressed finding alone is what its calibration rule already did, so Fix is the only call.
    test "a finding a calibration rule suppressed offers Fix only, and names the rule", %{
      conn: conn,
      project: project,
      task: task,
      code: code
    } do
      rule = learning(project, %{rule: "Don't flag a missing nil clause", kind: :calibration})
      {:ok, _saved} = Pipeline.save_finding(task, Map.put(code, :checklist_rule, rule.id))
      {:ok, _pass} = Pipeline.save_review(task)

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(
               view,
               "#finding-unhandled-nil[data-state='suppressed'] [data-qa='review_finding_state']",
               "Suppressed"
             )

      assert has_element?(view, "#finding-suppressor", "Don't flag a missing nil clause")
      assert has_element?(view, "#decide-fix-unhandled-nil")
      refute has_element?(view, "#decide-skip-unhandled-nil")
      assert has_element?(view, "#start-fix-round", "Finish review")
    end

    # A frame goes to the client rather than through the render, because it
    # arrives several times a second and nothing else on the page moves with it.
    test "a frame from the browser is pushed straight to the client", %{conn: conn, task: task} do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      send(view.pid, {:browser_frame, task.id, "some-base64"})
      _settled = render(view)

      assert_push_event(view, "browser:frame", %{data: "some-base64"})
    end

    # An animated page paints dozens of frames a second, more than the socket can
    # carry, and clicks queue behind them. Only the newest of a burst follows the first.
    test "a burst of frames reaches the client as its first and its newest", %{conn: conn, task: task} do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      for data <- ["first", "second", "newest"], do: send(view.pid, {:browser_frame, task.id, data})
      _settled = render(view)

      assert_push_event(view, "browser:frame", %{data: "first"})
      assert_push_event(view, "browser:frame", %{data: "newest"}, 1_000)
      refute_push_event(view, "browser:frame", %{data: "second"}, 0)
    end

    # A page that has stopped moving owes its viewer nothing, and the next change
    # on it should show at once rather than wait out a window.
    test "a frame after a quiet window goes straight to the client", %{conn: conn, task: task} do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      send(view.pid, {:browser_frame, task.id, "first"})
      send(view.pid, :frame_window_closed)
      send(view.pid, {:browser_frame, task.id, "after the lull"})
      _settled = render(view)

      assert_push_event(view, "browser:frame", %{data: "first"})
      assert_push_event(view, "browser:frame", %{data: "after the lull"}, 0)
    end

    # Every explorer and the demo recorder drive a browser of their own, and a page that keeps repainting
    # would send frames nobody sees. So only the browser the Browser item is open on is heard.
    test "only the browser the Browser item is open on is heard", %{conn: conn, task: task} do
      now = DateTime.utc_now()
      Repo.insert!(%BrowserSession{task_id: task.id, name: "explorer-1", status: :running, started_at: now})

      Repo.insert!(%BrowserSession{
        task_id: task.id,
        name: "demo",
        status: :running,
        started_at: DateTime.shift(now, second: 1)
      })

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      Phoenix.PubSub.broadcast(Rail.PubSub, "browser:#{task.id}:explorer-1", {:browser_frame, task.id, "unseen"})
      _settled = render(view)
      refute_push_event(view, "browser:frame", %{data: "unseen"}, 100)

      view |> element("#review-item-browser") |> render_click()
      Phoenix.PubSub.broadcast(Rail.PubSub, "browser:#{task.id}:explorer-1", {:browser_frame, task.id, "explorer's"})
      _settled = render(view)
      assert_push_event(view, "browser:frame", %{data: "explorer's"})

      send(view.pid, :frame_window_closed)
      view |> element("#review-browser-demo") |> render_click()
      Phoenix.PubSub.broadcast(Rail.PubSub, "browser:#{task.id}:explorer-1", {:browser_frame, task.id, "not picked"})
      Phoenix.PubSub.broadcast(Rail.PubSub, "browser:#{task.id}:demo", {:browser_frame, task.id, "demo's"})
      _settled = render(view)
      assert_push_event(view, "browser:frame", %{data: "demo's"})
      refute_push_event(view, "browser:frame", %{data: "not picked"}, 100)

      send(view.pid, :frame_window_closed)
      view |> element("#review-item-findings") |> render_click()
      Phoenix.PubSub.broadcast(Rail.PubSub, "browser:#{task.id}:demo", {:browser_frame, task.id, "item closed"})
      _settled = render(view)
      refute_push_event(view, "browser:frame", %{data: "item closed"}, 100)
    end

    # A frame for a task nobody is reading is nothing to send anywhere.
    test "a frame for another task is ignored", %{conn: conn, task: task} do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      send(view.pid, {:browser_frame, "tsk_somebody_else", "some-base64"})
      _settled = render(view)

      refute_push_event(view, "browser:frame", %{data: "some-base64"}, 100)
    end
  end

  describe "the questions gate" do
    setup %{project: project, run: run} do
      {:ok, dana} =
        Users.register_oauth_user(%{
          github_id: "gh_gate",
          login: "dana_gate",
          name: "Dana Okafor",
          email: "dana@gate.example"
        })

      earlier = learnings_task(project, "GATE-1")

      past = %Question{
        id: "qst_tlv_gate",
        prompt: "Indigo or blue?",
        answer: "Blue, to match the review tab.",
        status: :answered,
        answered_by_id: dana.id
      }

      {:ok, [rule]} = Rail.Learnings.record_corrections(earlier, [past])

      {:ok, blocked} =
        Pipeline.update_run(run, %{status: :blocked_on_input, stage_outcome: :in_progress, conversation_id: "sess_gate"})

      blocked = Repo.preload(blocked, task: :issue)

      {:ok, first} =
        Pipeline.register_question(blocked, %DetectedQuestion{prompt: "Do dismissed findings count as decided?"})

      {:ok, second} = Pipeline.register_question(blocked, %DetectedQuestion{prompt: "Which color is the Send button?"})

      {:ok, _by_rail} =
        first
        |> Question.changeset(%{
          answer: "Yes. Only Fix goes back.",
          status: :answered,
          answered_by_rail: true,
          suggested_learning_id: rule.id
        })
        |> Repo.update()

      {:ok, _suggested} = second |> Question.changeset(%{suggested_learning_id: rule.id}) |> Repo.update()

      %{questions: [first, second], rule: rule}
    end

    test "a question Rail answered says so, with its source, and can be changed", %{conn: conn, task: task} do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "#rail-answer-1", "Rail answered question 1 from a past answer")
      assert has_element?(view, "#rail-answer-1", "“Yes. Only Fix goes back.”")
      assert has_element?(view, "#rail-answer-1", "Dana Okafor on")
      assert has_element?(view, "#rail-answer-1 a", "GATE-1")
      assert has_element?(view, "[data-qa='saved-answer']", "Yes. Only Fix goes back.")
      assert render(view) =~ "Rail&#39;s answer, from a past answer"

      view |> element("#change-rail-answer-1") |> render_click()
      assert has_element?(view, "#answer-textarea", "Yes. Only Fix goes back.")
    end

    test "Use this answer answers with the past answer, and Answer myself puts the box away", %{
      conn: conn,
      task: task,
      questions: [_first, second]
    } do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      view |> element("#question-tab-1") |> render_click()

      assert has_element?(view, "#likely-answer", "Blue, to match the review tab.")
      refute has_element?(view, "#likely-answer", "When asked")
      assert has_element?(view, "#likely-answer", "Dana Okafor on")

      view |> element("#answer-myself") |> render_click()
      refute has_element?(view, "#likely-answer")
      assert has_element?(view, "#answer-textarea")

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      view |> element("#question-tab-1") |> render_click()
      view |> element("#use-likely-answer") |> render_click()

      assert %{status: :answered, answer: "Blue, to match the review tab.", answered_by_rail: false} =
               Repo.reload!(second)
    end

    test "a rule a person reworded is offered as it reads now", %{conn: conn, task: task, rule: rule} do
      {:ok, _edited} = Rail.Learnings.update_learning(system_scope(), rule, %{rule: "Blue, as the review tab is."})

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      view |> element("#question-tab-1") |> render_click()

      assert has_element?(view, "#likely-answer", "Blue, as the review tab is.")
      refute has_element?(view, "#likely-answer", "Blue, to match the review tab.")
    end
  end

  describe "a split" do
    setup %{project: project, run: run} do
      stub(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)
      roles = Map.new([:plan, :engineer, :review], &{&1, elem(Roles.get_role(project_id: project.id, stage: &1), 1)})

      # 1 waits on a person, 2 waits on 1, 3 failed.
      for {identifier, title} <- [
            {"TLV-10", "Work on TLV-10"},
            {"TLV-11", "Child TLV-11"},
            {"TLV-12", "Child TLV-12"},
            {"TLV-13", "Child TLV-13"}
          ] do
        Req.Test.expect(Rail.Linear, fn conn ->
          Req.Test.json(conn, %{
            "data" => %{
              "issueCreate" => %{
                "success" => true,
                "issue" => %{"id" => "lin_#{identifier}", "identifier" => identifier, "title" => title}
              }
            }
          })
        end)
      end

      {:ok, parent_issue} = Issues.create_issue(system_scope(), project, %{title: "Work on TLV-10"})
      {:ok, parent} = Pipeline.create_task(parent_issue, :split)
      parent = Repo.preload(parent, [:issue, :project])

      [first, second, third] =
        children =
        for {{identifier, builds_on}, number} <- Enum.with_index([{"TLV-11", []}, {"TLV-12", [1]}, {"TLV-13", []}], 1) do
          attrs = %{title: "Child #{identifier}", parent: parent_issue}
          {:ok, issue} = Issues.create_issue(system_scope(), project, attrs)
          part = %{number: number, builds_on: builds_on, plan: "## Implementation plan\n\nPart #{number}."}
          {:ok, child} = Pipeline.create_child_task(parent, issue, part)
          Repo.preload(child, [:issue, :project])
        end

      on_exit(fn -> Enum.each([parent | children], &File.rm_rf(&1.scratch_path)) end)

      {:ok, _plan} = Pipeline.update_run(run, %{task_id: parent.id})

      {:ok, first_run} =
        Pipeline.create_run(%{
          task_id: first.id,
          role_id: roles[:engineer].id,
          status: :finished,
          stage_outcome: :done,
          started_at: DateTime.utc_now()
        })

      {:ok, _failed} =
        Pipeline.create_run(%{
          task_id: third.id,
          role_id: roles[:engineer].id,
          status: :failed,
          error: "Chrome could not reach it",
          started_at: DateTime.utc_now()
        })

      %{parent: parent, first: first, second: second, third: third, roles: roles, first_run: first_run}
    end

    test "the parent opens on its Children tab, right after Plan, its badge counting the children waiting on a person",
         %{conn: conn, parent: parent, roles: roles, scope: scope} do
      assert {:ok, view, html} = live(conn, ~p"/tasks/#{parent.id}")

      assert ["task-tab-issue", "task-tab-#{roles[:plan].id}", "task-tab-children"] ==
               html |> Floki.parse_document!() |> Floki.find("[role='tab']") |> Floki.attribute("id")

      assert has_element?(view, "#task-tab-children[aria-selected='true']", "0 of 3 merged")
      assert has_element?(view, "#task-tab-issue[aria-selected='false']")
      assert has_element?(view, "#task-tab-children [data-qa='task-tab-badge']", "2")
      assert has_element?(view, "#task-tab-#{roles[:plan].id}", "approved, split into 3")
      assert has_element?(view, "[data-qa='task_status_chip']", "2 children need attention")
      refute has_element?(view, "[data-qa='task_branch_name']")
      refute has_element?(view, "#child-switcher")

      # Only the split's owner is told the children need them.
      parent.issue |> Issue.linear_changeset(%{owner_user_id: scope.user.id}) |> Repo.update!()
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{parent.id}")
      assert has_element?(view, "[data-qa='task_status_chip']", "2 children need you")
    end

    test "each row says where its child stands, and its action opens that child's tab", %{
      conn: conn,
      parent: parent,
      first: first,
      roles: roles
    } do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{parent.id}")

      assert has_element?(view, "#split-row-TLV-11", "Child TLV-11")
      assert has_element?(view, "#split-row-TLV-11", "starts at once")
      assert has_element?(view, "#split-row-TLV-11 [data-qa='split-row-line']", "Diff ready for review")
      assert has_element?(view, "#split-row-TLV-12", "after TLV-11")
      assert has_element?(view, "#split-row-TLV-12[data-state='waiting_on']", "Starts when TLV-11 merges")
      assert has_element?(view, "#split-row-TLV-13[data-state='failed']", "Engineer failed: Chrome could not reach it")
      assert has_element?(view, "#split-row-TLV-13 [data-qa='split-row-badge']")

      view |> element("#split-action-TLV-11", "Review the diff") |> render_click()

      assert_patch(view, ~p"/tasks/#{parent.id}?child=TLV-11&tab=#{roles[:engineer].id}")
      assert has_element?(view, "[data-qa='task_detail_title']", "Child TLV-11")
      assert has_element?(view, "#task-tab-#{roles[:engineer].id}[aria-selected='true']")
      assert has_element?(view, "[data-qa='task_branch_name']", first.worktree_name)
    end

    test "a child's own path lands on its parent's with it selected, and a reload keeps it", %{
      conn: conn,
      parent: parent,
      second: second
    } do
      to = ~p"/tasks/#{parent.id}?child=TLV-12"
      assert {:error, {:live_redirect, %{to: ^to}}} = live(conn, ~p"/tasks/#{second.id}")

      assert {:ok, view, _html} = live(conn, to)
      assert has_element?(view, "[data-qa='task_detail_title']", "Child TLV-12")
    end

    test "a link to a file on a child's own path keeps the file on the way to its parent's", %{
      conn: conn,
      parent: parent,
      first: first,
      roles: roles
    } do
      remote = create_temp_git_repo(prefix: "rail_git_remote", initial_commit: false)
      git!(remote, ["config", "receive.denyCurrentBranch", "ignore"])
      repo = create_temp_git_repo()
      git!(repo, ["remote", "add", "origin", remote])
      git!(repo, ["push", "origin", "main"])
      git!(repo, ["checkout", "-b", "feature"])
      File.write!(Path.join(repo, "shipped.ex"), "committed\n")
      git!(repo, ["add", "."])
      git!(repo, ["commit", "-m", "the engineer's work"])
      {:ok, _child} = Pipeline.update_task(first, %{worktree_path: repo})

      to = ~p"/tasks/#{parent.id}?child=TLV-11&tab=#{roles[:engineer].id}&file=shipped.ex"

      assert {:error, {:live_redirect, %{to: ^to}}} =
               live(conn, ~p"/tasks/#{first.id}?tab=#{roles[:engineer].id}&file=shipped.ex")

      assert {:ok, view, _html} = live(conn, to)
      assert has_element?(view, "#diff-scroller[data-scroll-to='shipped.ex']")
    end

    test "a waiting child shows only Issue, Plan and Children, its approved part and no conversation or branch", %{
      conn: conn,
      parent: parent,
      roles: roles
    } do
      assert {:ok, view, html} = live(conn, ~p"/tasks/#{parent.id}?child=TLV-12")

      assert ["task-tab-issue", "task-tab-#{roles[:plan].id}", "task-tab-children"] ==
               html |> Floki.parse_document!() |> Floki.find("[role='tab']") |> Floki.attribute("id")

      assert has_element?(view, "#task-tab-#{roles[:plan].id}[aria-selected='true']", "approved in TLV-10")
      assert has_element?(view, "[data-qa='task_status_chip']", "Waiting on TLV-11")
      refute has_element?(view, "[data-qa='task_branch_name']")
      refute has_element?(view, "#task-conversation-column")
      assert has_element?(view, "#child-plan-approved", "Approved in TLV-10 · part 2 of 3")
      assert has_element?(view, "#child-plan-waiting", "Starts when TLV-11 merges.")
      assert has_element?(view, "#child-plan", "Part 2.")
      refute has_element?(view, "#approve-plan")
    end

    test "a child's Children tab goes back to its parent's board", %{conn: conn, parent: parent} do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{parent.id}?child=TLV-11")

      view |> element("#task-tab-children") |> render_click()

      assert_patch(view, ~p"/tasks/#{parent.id}?tab=children")
      assert has_element?(view, "#split-board")
      assert has_element?(view, "[data-qa='task_detail_title']", "Work on TLV-10")
    end

    test "the switcher lists every child with where it stands, and steps to its neighbors", %{
      conn: conn,
      parent: parent,
      scope: scope
    } do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{parent.id}?child=TLV-12")

      assert has_element?(view, "#child-switcher-button", "2 of 3")
      assert has_element?(view, "#child-switcher-TLV-11", "Review the diff")
      assert has_element?(view, "#child-switcher-TLV-12[aria-current='true']", "Waiting on TLV-11")
      assert has_element?(view, "#child-switcher-TLV-13", "Engineer failed")
      assert has_element?(view, "#child-switcher-all", "All children of TLV-10")
      assert has_element?(view, "#child-switcher-waiting[class*='slate']", "2 other children need attention")

      parent.issue |> Issue.linear_changeset(%{owner_user_id: scope.user.id}) |> Repo.update!()
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{parent.id}?child=TLV-12")
      assert has_element?(view, "#child-switcher-waiting[class*='amber']", "2 other children need you")

      view |> element("#child-switcher-TLV-11") |> render_click()
      assert_patch(view, ~p"/tasks/#{parent.id}?child=TLV-11")
      assert has_element?(view, "#child-switcher-button", "1 of 3")

      view |> element("#child-switcher-all") |> render_click()
      assert_patch(view, ~p"/tasks/#{parent.id}?tab=children")
      assert has_element?(view, "#split-board")

      view |> element("#split-open-TLV-12") |> render_click()
      assert_patch(view, ~p"/tasks/#{parent.id}?child=TLV-12")

      view |> element("a#child-next") |> render_click()
      assert_patch(view, ~p"/tasks/#{parent.id}?child=TLV-13")
      refute has_element?(view, "a#child-next")
      assert has_element?(view, "span#child-next[aria-disabled='true']")

      view |> element("a#child-previous") |> render_click()
      assert_patch(view, ~p"/tasks/#{parent.id}?child=TLV-12")
    end

    test "a selected child offers Update branch, and its tabs keep it in the URL", %{
      conn: conn,
      parent: parent,
      first: first,
      roles: roles
    } do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{parent.id}?child=TLV-11")

      assert has_element?(view, "#update-branch")
      assert has_element?(view, "#child-switcher")

      expect(Pipeline, :update_branch, fn _scope, %Task{id: id} = task ->
        assert id == first.id
        {:ok, task}
      end)

      view |> element("#update-branch") |> render_click()
      assert_patch(view, ~p"/tasks/#{parent.id}?child=TLV-11&tab=#{roles[:engineer].id}")

      view |> element("#task-tab-issue") |> render_click()
      assert_patch(view, ~p"/tasks/#{parent.id}?child=TLV-11&tab=issue")
    end

    test "a child moving on or merging updates its row without a reload", %{
      conn: conn,
      parent: parent,
      first: first,
      first_run: first_run
    } do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{parent.id}")

      {:ok, _running} = Pipeline.update_run(first_run, %{status: :running, stage_outcome: :in_progress})
      send(view.pid, {:pipeline_changed, first.id})
      assert has_element?(view, "#split-row-TLV-11[data-state='running']")

      first.issue |> Issue.linear_changeset(%{state: :done, completed_at: DateTime.utc_now(:second)}) |> Repo.update!()
      send(view.pid, {:issue_changed, first.issue_id})
      assert has_element?(view, "#split-row-TLV-11[data-state='merged']", "Merged")
      assert has_element?(view, "#task-tab-children", "1 of 3 merged")

      send(view.pid, {:pipeline_changed, "tsk_elsewhere"})
      send(view.pid, {:issue_changed, "iss_elsewhere"})
      send(view.pid, {:issue_created, "iss_elsewhere"})
      assert has_element?(view, "#split-board")
    end

    test "a parent whose children have all merged reads Merged", %{conn: conn, parent: parent} do
      {:ok, _merged} = Pipeline.update_task(parent, %{stage: :merged})
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{parent.id}")

      assert has_element?(view, "[data-qa='task_status_chip']", "2 children need attention")

      for child <- Pipeline.list_tasks(parent_task_id: parent.id, preload: [:issue]) do
        child.issue |> Issue.linear_changeset(%{completed_at: DateTime.utc_now(:second)}) |> Repo.update!()
      end

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{parent.id}")
      assert has_element?(view, "[data-qa='task_status_chip']", "Merged")
      assert has_element?(view, "#task-tab-children", "3 of 3 merged")
    end

    test "the switcher sits above a child's title on every tab it has", %{
      conn: conn,
      parent: parent,
      first: first,
      project: project
    } do
      for stage <- [:review_lead, :debugger] do
        {:ok, role} = Roles.get_role(project_id: project.id, stage: stage)

        {:ok, _run} =
          Pipeline.create_run(%{task_id: first.id, role_id: role.id, status: :running, started_at: DateTime.utc_now()})

        assert {:ok, view, _html} = live(conn, ~p"/tasks/#{parent.id}?child=TLV-11&tab=#{role.id}")
        assert has_element?(view, "#task-tab-#{role.id}[aria-selected='true']")
        assert has_element?(view, "#child-switcher", "1 of 3")
      end
    end

    test "with nobody waiting the parent reads Plan approved, its Children tab toned by what its children do", %{
      conn: conn,
      parent: parent,
      first_run: first_run,
      third: third
    } do
      third_run = Repo.get_by!(Run, task_id: third.id)
      {:ok, _running} = Pipeline.update_run(first_run, %{status: :running, stage_outcome: :in_progress})
      {:ok, _waiting} = Pipeline.update_run(third_run, %{status: :waiting_for_resources, error: nil})

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{parent.id}")
      assert has_element?(view, "[data-qa='task_status_chip']", "Plan approved")
      assert has_element?(view, "#task-tab-children [data-tone='running']")
      refute has_element?(view, "#task-tab-children [data-qa='task-tab-badge']")

      {:ok, _waiting} = Pipeline.update_run(first_run, %{status: :waiting_for_resources})
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{parent.id}")
      assert has_element?(view, "#task-tab-children [data-tone='idle']")
    end

    test "a child's pending questions are counted on its row and in the switcher", %{
      conn: conn,
      parent: parent,
      first_run: first_run
    } do
      {:ok, blocked} = Pipeline.update_run(first_run, %{status: :blocked_on_input, stage_outcome: :in_progress})
      blocked = Repo.preload(blocked, task: :issue)
      {:ok, _question} = Pipeline.register_question(blocked, %DetectedQuestion{prompt: "Which region?"})

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{parent.id}")
      assert has_element?(view, "#split-row-TLV-11 [data-qa='split-row-badge']", "1")
      assert has_element?(view, "#split-action-TLV-11", "Answer")

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{parent.id}?child=TLV-12")
      assert has_element?(view, "#child-switcher-TLV-11 [aria-label='1 waiting on you']", "1")
    end

    test "an unowned child is owned through its parent: no Claim, and its owner cannot be changed", %{
      conn: conn,
      parent: parent,
      first: first,
      scope: scope
    } do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{parent.id}?child=TLV-11&tab=issue")

      refute has_element?(view, "#claim-task")
      assert has_element?(view, "#issue-owner", "Unassigned")
      refute has_element?(view, "#issue-owner-menu")

      render_hook(view, "assign", %{"user_id" => scope.user.id})
      assert %Issue{owner_user_id: nil} = Repo.reload!(first.issue)

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{parent.id}")
      assert has_element?(view, "#claim-task")
    end

    test "a split is cleaned up from its parent, which warns until Linear has marked every child done", %{
      conn: conn,
      parent: parent,
      first: first,
      second: second,
      third: third
    } do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{parent.id}?child=TLV-11")
      refute has_element?(view, "#cleanup-task")

      first.issue |> Issue.linear_changeset(%{state: :done}) |> Repo.update!()
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{parent.id}")

      assert view |> element("#cleanup-task") |> render() =~
               "2 of 3 children are not marked done in Linear: TLV-12, TLV-13. Clean up this task and all of its children anyway?"

      for child <- [second, third], do: child.issue |> Issue.linear_changeset(%{state: :done}) |> Repo.update!()

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{parent.id}")
      assert view |> element("#cleanup-task") |> render() =~ "Clean up this task and its 3 children?"
    end

    test "a child building on a canceled sibling reads Blocked by it, on its row and in its header", %{
      conn: conn,
      parent: parent,
      first: first
    } do
      first.issue |> Issue.linear_changeset(%{state: :canceled}) |> Repo.update!()

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{parent.id}")
      assert has_element?(view, "#split-row-TLV-12[data-state='blocked_by_canceled']", "TLV-11 was canceled")

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{parent.id}?child=TLV-12")
      assert has_element?(view, "[data-qa='task_status_chip']", "Blocked by TLV-11")
      refute has_element?(view, "[data-qa='task_branch_name']")
    end

    test "a child removed in Linear leaves the split counted as it was approved", %{
      conn: conn,
      project: project,
      parent: parent,
      first: first,
      roles: roles
    } do
      {:ok, workspace} = Projects.get_linear_workspace(id: project.linear_workspace_id)
      remove = %{"type" => "Issue", "action" => "remove", "data" => %{"id" => first.issue.external_id}}
      assert {:ok, _removed} = Issues.handle_linear_webhook(workspace, remove)

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{parent.id}")
      assert has_element?(view, "#split-row-TLV-12", "after child 1")
      refute has_element?(view, "#split-row-TLV-12", "starts at once")

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{parent.id}?child=TLV-13&tab=#{roles[:plan].id}")
      assert has_element?(view, "#child-plan-approved", "part 3 of 3")
      assert has_element?(view, "#child-switcher-button", "3 of 3")
    end

    test "a task with no split has no Children tab and no switcher", %{conn: conn, task: task} do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      refute has_element?(view, "#task-tab-children")
      refute has_element?(view, "#child-switcher")
    end
  end
end
