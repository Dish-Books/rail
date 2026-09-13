defmodule RailWeb.TaskLiveTest do
  use RailWeb.ConnCase, async: true

  import Mimic
  import Phoenix.LiveViewTest

  alias Rail.Backends
  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Runs
  alias Rail.Runs.DetectedQuestion
  alias Rail.Runs.Schemas.OsProcess
  alias Rail.Runs.Schemas.Run
  alias Rail.Scope
  alias Rail.Users
  alias RailTest.Mocks.Linear, as: LinearMock

  setup %{conn: conn} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_task_live",
        login: "task_live_user",
        email: "task_live_user@example.com",
        admin: true
      })

    scope = Scope.for_user(user)

    {:ok, backend} = Backends.create_backend(system_scope(), %{name: :claude, executable_path: "/usr/bin/true"})

    {:ok, workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Task Live Workspace",
        external_id: "lin_ws_task_live",
        token: "lin_api_token_task_live",
        webhook_secret: "whsec_task_live"
      })

    {:ok, project} =
      Projects.create_project(scope, %{
        name: "Task Live Project",
        github_repo: "org/task-live",
        github_installation_id: 46_001,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_task_live",
        linear_team_key: "TLV",
        default_branch: "main",
        clone_path: "/tmp/repos/task-live",
        active: true,
        linear_state_ids: %{"triage" => "st_triage"}
      })

    {:ok, role} =
      Roles.create_role(scope, project, %{
        backend_id: backend.id,
        stage: :product,
        name: "product role",
        model: "claude-3-7-sonnet",
        system_prompt: "You are the product agent."
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_live_1",
      "identifier" => "TLV-1",
      "title" => "Task Live Issue"
    })

    {:ok, issue} = Issues.create_issue(project, %{description: "Task Live Issue"})
    {:ok, task} = Pipeline.create_task(issue, :product)
    File.mkdir_p!(Path.join(task.scratch_path, "tickets"))
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    {:ok, run} =
      Runs.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :finished,
        stage_outcome: :done,
        started_at: DateTime.utc_now()
      })

    %{
      conn: log_in_user(conn, user),
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
    assert has_element?(view, "[data-qa='task_status_chip']", "Review the ticket")
  end

  test "a run that recorded an error shows it", %{conn: conn, task: task, run: run} do
    {:ok, _failed} = Runs.update_run(run, %{error: "The agent gave up."})

    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    assert has_element?(view, "[data-qa='task_error_card']", "The agent gave up.")
  end

  test "the page hosts the conversation for the runs the task has", %{conn: conn, task: task, role: role} do
    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    assert has_element?(view, "[data-qa='conversation-tab']")
    assert has_element?(view, "#role-chip-#{role.id}")
  end

  test "the product stage renders the ticket and approving hands the task on", %{
    conn: conn,
    task: task,
    run: run
  } do
    # Approving is a one-way door, so the run has to be one that has not been through it.
    {:ok, _open} = Runs.update_run(run, %{stage_outcome: :in_progress})

    File.write!(
      Path.join([task.scratch_path, "tickets", "TLV-1.md"]),
      "---\ntitle: A better ticket\n---\n\nThe body the agent wrote."
    )

    LinearMock.mock_update_issue_success(%{"id" => "lin_task_live_1", "identifier" => "TLV-1"})

    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
    assert has_element?(view, "[data-qa='product_ticket']", "The body the agent wrote.")

    view |> element("#approve-product-plan") |> render_click()

    assert %Task{stage: :design} = Repo.reload!(task)
    assert %{title: "A better ticket"} = task |> Repo.reload!() |> Repo.preload(:issue) |> Map.fetch!(:issue)
  end

  test "the product stage says so when the agent has written no ticket", %{conn: conn, task: task} do
    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    assert has_element?(view, "[data-qa='product_ticket_pending']")
    refute has_element?(view, "#approve-product-plan")
  end

  test "a blocked run's questions are answered here and sent as one round", %{
    conn: conn,
    task: task,
    run: run
  } do
    {:ok, blocked} = Runs.update_run(run, %{status: :blocked_on_input, stage_outcome: :in_progress})
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

    assert [] = Pipeline.list_questions(task.id, status: :pending)
  end

  test "a question can be dismissed instead of answered", %{conn: conn, task: task, run: run} do
    {:ok, blocked} = Runs.update_run(run, %{status: :blocked_on_input, stage_outcome: :in_progress})
    blocked = Repo.preload(blocked, task: :issue)

    {:ok, question} = Pipeline.register_question(blocked, %DetectedQuestion{prompt: "Which database?"})

    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    view |> element("#dismiss-question-button") |> render_click()

    assert {:ok, %{status: :dismissed}} = Pipeline.get_question(question.id)
  end

  test "a blank answer is not recorded", %{conn: conn, task: task, run: run} do
    {:ok, blocked} = Runs.update_run(run, %{status: :blocked_on_input, stage_outcome: :in_progress})
    blocked = Repo.preload(blocked, task: :issue)

    {:ok, question} = Pipeline.register_question(blocked, %DetectedQuestion{prompt: "Which database?"})

    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    view |> form("#answer-question-form", %{"answer" => "   "}) |> render_submit()

    assert {:ok, %{status: :pending}} = Pipeline.get_question(question.id)
  end

  test "cleaning up releases the disk the task was holding", %{conn: conn, task: task} do
    assert File.dir?(task.scratch_path)

    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    view |> element("#cleanup-task") |> render_click()
    _settled = render_async(view)

    refute File.dir?(task.scratch_path)
  end

  test "a task that is already gone reads as cleaned up", %{conn: conn} do
    assert {:ok, view, _html} = live(conn, ~p"/tasks/tsk_missing")

    assert has_element?(view, "#task-cleaned-up")
  end

  describe "the conversation, which the page hosts and feeds" do
    setup %{backend: backend, project: project, task: task, run: run} do
      {:ok, other_role} =
        Roles.create_role(system_scope(), project, %{
          backend_id: backend.id,
          stage: :design,
          name: "design role",
          model: "claude-3-7-sonnet",
          system_prompt: "You are the design agent."
        })

      {:ok, _other_run} =
        Runs.create_run(%{
          task_id: task.id,
          role_id: other_role.id,
          status: :finished,
          conversation_id: "sess_design",
          started_at: ~U[2026-09-09 09:00:00Z]
        })

      {:ok, working} =
        Runs.update_run(run, %{
          status: :running,
          stage_outcome: :in_progress,
          conversation_id: "sess_product",
          started_at: ~U[2026-09-09 10:00:00Z]
        })

      Runs.append_run_event(working, "[tool read_file] lib/rail.ex")

      {:ok, task} = Pipeline.update_task(task, %{worktree_path: create_temp_git_repo()})

      %{task: task, run: working, other_role: other_role}
    end

    test "switches to another role on request", %{conn: conn, task: task, other_role: other_role} do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "#role-chip-#{other_role.id}")

      view |> element("#role-chip-#{other_role.id}") |> render_click()

      assert has_element?(view, "#conversation-tab-root")
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

      view |> element("[data-qa='activity-tile'] button") |> render_click()
      refute has_element?(view, "[data-qa='activity-content']")
    end

    test "a message typed while the agent works waits on its run", %{conn: conn, task: task, run: run} do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      view |> element("#chat-composer-form") |> render_change(%{"message" => "Please add a test"})
      view |> element("#chat-composer-form") |> render_submit(%{"message" => "Please add a test"})

      assert has_element?(view, "#queued-banner", "Please add a test")
      assert %Run{pending_chat: "Please add a test"} = Repo.reload!(run)
    end

    test "stopping hands the undelivered message back to the composer", %{conn: conn, task: task, run: run} do
      {:ok, _queued} = Runs.update_run(run, %{pending_chat: "Please add a test"})

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      view |> element("#cancel-queued-message") |> render_click()

      assert has_element?(view, "#chat-input[value='Please add a test']")
      assert %Run{pending_chat: nil, status: :finished} = Repo.reload!(run)
    end

    test "send now cuts the turn short and delivers what was queued", %{conn: conn, task: task, run: run} do
      {:ok, _queued} = Runs.update_run(run, %{pending_chat: "Please add a test"})

      stub(Runs, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)

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

      send(view.pid, {:run_events, run.id, [%{line: "A fresh line of output"}]})

      # The page forwards to the component, which renders on its own turn.
      _settled = render(view)
      assert render(view) =~ "A fresh line of output"
    end

    test "log lines for a run the page is not following are ignored", %{conn: conn, task: task} do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      send(view.pid, {:run_events, "run_somebody_else", [%{line: "Not for this page"}]})

      refute render(view) =~ "Not for this page"
    end

    test "an OS process finishing refreshes the page", %{conn: conn, task: task, run: run} do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      {:ok, _failed} = Runs.update_run(run, %{status: :finished, error: "It fell over."})
      send(view.pid, {:os_process_finished, run, %{}})

      assert has_element?(view, "[data-qa='task_error_card']", "It fell over.")
    end
  end
end
