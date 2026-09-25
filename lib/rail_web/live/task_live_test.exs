defmodule RailWeb.TaskLiveTest do
  use RailWeb.ConnCase, async: true

  import Mimic
  import Phoenix.LiveViewTest

  alias Rail.Git
  alias Rail.GitHub.Client
  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.DetectedQuestion
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Scope
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess
  alias Rail.Users

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

    {:ok, role} = Roles.get_role(project_id: project.id, stage: :product)

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
    {:ok, task} = Pipeline.create_task(issue, :product)
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
    assert has_element?(view, "[data-qa='task_status_chip']", "Review the ticket")
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

  test "the product stage renders the ticket and approving hands the task on", %{conn: conn, task: task} do
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: create_temp_git_repo()})

    File.write!(
      Path.join([task.scratch_path, "tickets", "TLV-1.md"]),
      "---\ntitle: A better ticket\npriority: high\nestimate: 2\n---\n\nThe body the agent wrote."
    )

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueUpdate" => %{"success" => true, "issue" => %{"id" => "lin_task_live_1", "identifier" => "TLV-1"}}
        }
      })
    end)

    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
    assert has_element?(view, "[data-qa='product_ticket']", "The body the agent wrote.")
    assert has_element?(view, "#product-ticket-title", "A better ticket")
    assert has_element?(view, "#product-ticket-priority", "High")
    assert has_element?(view, "#product-ticket-estimate", "2 Points")
    refute has_element?(view, "[data-qa='product_ticket']", "title:")

    view |> element("#approve-product-plan") |> render_click()

    assert %Task{stage: :design} = Repo.reload!(task)
    assert %{title: "A better ticket"} = task |> Repo.reload!() |> Repo.preload(:issue) |> Map.fetch!(:issue)
  end

  test "the product stage says so when the agent has written no ticket", %{conn: conn, task: task} do
    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    assert has_element?(view, "[data-qa='product_ticket_pending']")
    refute has_element?(view, "#approve-product-plan")
  end

  test "a running stage offers no approval", %{conn: conn, task: task, run: run} do
    {:ok, _working} = Pipeline.update_run(run, %{status: :running, stage_outcome: :in_progress})
    File.write!(Path.join([task.scratch_path, "tickets", "TLV-1.md"]), "# A ticket\n\nBody.")

    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    refute has_element?(view, "#approve-product-plan")
    refute has_element?(view, "#approve-product-plan-skip-design")
  end

  test "approving a run that started working since the page loaded says so", %{conn: conn, task: task, run: run} do
    File.write!(Path.join([task.scratch_path, "tickets", "TLV-1.md"]), "# A ticket\n\nBody.")

    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
    {:ok, _working} = Pipeline.update_run(run, %{status: :running, stage_outcome: :in_progress})

    view |> element("#approve-product-plan") |> render_click()

    assert has_element?(view, "#product-approve-error", "still running")
  end

  test "approving a task that has moved on says where it is", %{conn: conn, task: task} do
    File.write!(Path.join([task.scratch_path, "tickets", "TLV-1.md"]), "# A ticket\n\nBody.")

    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    {:ok, _moved} = Pipeline.update_task(task, %{stage: :design})
    view |> element("#approve-product-plan") |> render_click()

    assert has_element?(view, "#product-approve-error", "at Design, not product")
  end

  test "approving a ticket with no title reports why it failed", %{conn: conn, task: task} do
    File.write!(Path.join([task.scratch_path, "tickets", "TLV-1.md"]), "Just a body, no heading.")

    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
    assert has_element?(view, "[data-qa='task_detail_title']", "Task Live Issue")

    view |> element("#approve-product-plan") |> render_click()

    assert has_element?(view, "#product-approve-error", "Could not approve the ticket")
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
        error: "agy reported ERROR: Eligibility check failed",
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

    # A rebase resumes the run without anyone answering what it asked.
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

  test "cleaning up releases the disk the task was holding", %{conn: conn, task: task} do
    assert File.dir?(task.scratch_path)

    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    view |> element("#cleanup-task") |> render_click()

    assert_redirect(view, ~p"/issues/#{task.issue_id}", 1_000)
    refute File.dir?(task.scratch_path)
    assert {:ok, %Task{cleaned_up_at: %DateTime{}}} = Pipeline.get_task(task.id)
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

  describe "the tabs across the header" do
    test "the issue comes first and the stage's role is the one open", %{conn: conn, task: task, role: role} do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "#task-tab-issue", "Linear Issue")
      assert has_element?(view, "#task-tab-#{role.id}[aria-selected='true']", "review the ticket")
      assert has_element?(view, "[data-qa='product-stage']")
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
      refute has_element?(view, "[data-qa='product-stage']")
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

      {:ok, architect} = Roles.get_role(project_id: project.id, stage: :architect)

      {:ok, task} = Pipeline.update_task(task, %{stage: :architect})

      {:ok, _planning} =
        Pipeline.create_run(%{
          task_id: task.id,
          role_id: architect.id,
          status: :running,
          started_at: DateTime.utc_now()
        })

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      view |> element("#task-tab-#{role.id}") |> render_click()

      assert has_element?(view, "[data-qa='product_ticket']", "The ticket as approved.")
      refute has_element?(view, "[data-qa='approve_product_plan']")
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
      {:ok, architect} = Roles.get_role(project_id: project.id, stage: :architect)

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      refute has_element?(view, "#task-tab-#{architect.id}")
    end

    test "a blocked role counts what it is waiting on", %{conn: conn, task: task, role: role, run: run} do
      {:ok, blocked} = Pipeline.update_run(run, %{status: :blocked_on_input, stage_outcome: :in_progress})
      blocked = Repo.preload(blocked, task: :issue)

      {:ok, _first} = Pipeline.register_question(blocked, %DetectedQuestion{prompt: "Which flow?"})
      {:ok, _second} = Pipeline.register_question(blocked, %DetectedQuestion{prompt: "How many?"})

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "#task-tab-#{role.id} [data-qa='task-tab-badge']", "2")
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
      {:ok, architect} = Roles.get_role(project_id: project.id, stage: :architect)

      {:ok, _planning} =
        Pipeline.create_run(%{
          task_id: task.id,
          role_id: architect.id,
          status: :running,
          started_at: DateTime.utc_now()
        })

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}?tab=#{role.id}")
      assert has_element?(view, "#task-tab-#{role.id}[aria-selected='true']")

      {:ok, _moved} = Pipeline.update_task(task, %{stage: :architect})
      send(view.pid, :task_changed)

      assert has_element?(view, "#task-tab-#{architect.id}[aria-selected='true']")
      assert_patch(view, ~p"/tasks/#{task.id}?tab=#{architect.id}")
    end
  end

  describe "the design stage" do
    setup %{project: project, task: task} do
      {:ok, design_role} = Roles.get_role(project_id: project.id, stage: :design)

      {:ok, task} = Pipeline.update_task(task, %{stage: :design, worktree_path: create_temp_git_repo()})

      {:ok, design_run} =
        Pipeline.create_run(%{
          task_id: task.id,
          role_id: design_role.id,
          status: :finished,
          stage_outcome: :done,
          conversation_id: "sess_design_stage",
          started_at: DateTime.utc_now()
        })

      design_dir = Path.join(task.scratch_path, "design")
      File.mkdir_p!(design_dir)

      File.write!(
        Path.join(design_dir, "manifest.json"),
        Jason.encode!(%{
          "options" => [
            %{
              "key" => "cards",
              "title" => "Cards",
              "summary" => "Big tiles.",
              "good_at" => ["Easy to scan"],
              "costs" => ["Few per screen"],
              "assumptions" => "Twelve per page."
            },
            %{"key" => "table", "title" => "Table", "summary" => "Dense rows."},
            %{"key" => "timeline", "title" => "Timeline"}
          ]
        })
      )

      for key <- ["cards", "table", "timeline"], do: File.write!(Path.join(design_dir, "#{key}.html"), "<h1>#{key}</h1>")

      %{task: task, design_run: design_run, design_dir: design_dir}
    end

    test "says so when the designer has written nothing", %{conn: conn, task: task, design_dir: dir} do
      File.rm!(Path.join(dir, "manifest.json"))

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "[data-qa='design_pending']")
      assert has_element?(view, "#design-pending-title", "No design options yet")
      refute has_element?(view, "#approve-design")
    end

    test "says the designer is at work while it is", %{
      conn: conn,
      task: task,
      design_run: design_run,
      design_dir: dir
    } do
      File.rm!(Path.join(dir, "manifest.json"))
      {:ok, _working} = Pipeline.update_run(design_run, %{status: :running})

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "#design-pending-title", "Designing three options")
    end

    test "shows one option at a time, with its tradeoffs, and picking one tells the designer", %{
      conn: conn,
      task: task,
      design_dir: dir
    } do
      File.write!(Path.join(dir, "cards.png"), "png")
      stub(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "[data-qa='task_status_chip']", "Review the designs")
      assert has_element?(view, "#design-tab-cards[aria-selected='true'] img")
      assert has_element?(view, "#design-tab-table[aria-selected='false']")
      assert has_element?(view, "#design-tab-timeline")

      assert has_element?(view, "#design-option-title", "Cards")
      assert has_element?(view, "#design-option-cards", "Big tiles.")
      assert has_element?(view, "#design-good-at", "Easy to scan")
      assert has_element?(view, "#design-costs", "Few per screen")
      assert has_element?(view, "#design-assumptions", "Twelve per page.")
      assert has_element?(view, "#open-design-cards[href='/tasks/#{task.id}/design/cards']")
      refute has_element?(view, "#approve-design")

      view |> element("#design-tab-table") |> render_click()

      assert has_element?(view, "#design-option-table iframe[srcdoc='<h1>table</h1>']")
      refute has_element?(view, "#design-option-cards")
      refute has_element?(view, "#design-good-at")

      view |> element("#pick-design-table") |> render_click()

      assert File.read!(Path.join(dir, "picked")) == "table"
      assert has_element?(view, "#design-option-title", "Table")
      refute has_element?(view, "[data-qa='design_tab']")

      # Once there is a pick, acting on it sits in the header with every other
      # action on the task; approving waits for the designer's turn to finish.
      refute has_element?(view, "#task-header #approve-design")
      assert has_element?(view, "#task-header #open-design-table[href='/tasks/#{task.id}/design/table']")
      refute has_element?(view, "[data-qa='pick_design']")
    end

    test "a turn finishing re-reads the design the agent may have changed", %{
      conn: conn,
      task: task,
      design_run: design_run,
      design_dir: dir
    } do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      assert has_element?(view, "#design-option-cards", "Big tiles.")

      File.write!(
        Path.join(dir, "manifest.json"),
        ~s({"options": [{"key": "cards", "title": "Cards", "summary": "Bigger tiles."}]})
      )

      send(view.pid, {:os_process_finished, design_run, %{}})

      # The page forwards to the component, which renders on its own turn.
      _settled = render(view)
      assert has_element?(view, "#design-option-cards", "Bigger tiles.")
    end

    test "approving the picked design hands the task to the architect", %{conn: conn, task: task, design_dir: dir} do
      File.write!(Path.join(dir, "picked"), "cards")
      File.write!(Path.join(dir, "cards.png"), "png bytes")

      Req.Test.expect(Rail.Linear, fn conn ->
        Req.Test.json(conn, %{
          "data" => %{
            "fileUpload" => %{
              "success" => true,
              "uploadFile" => %{
                "uploadUrl" => "https://uploads.linear.app/put/tlv-1",
                "assetUrl" => "https://uploads.linear.app/assets/tlv-1-cards.png",
                "headers" => []
              }
            }
          }
        })
      end)

      Req.Test.expect(Rail.Linear, fn conn -> Plug.Conn.send_resp(conn, 200, "") end)

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      view |> element("#approve-design") |> render_click()

      assert %Task{stage: :architect} = Repo.reload!(task)
    end

    test "a design that cannot be approved says why", %{conn: conn, task: task, design_dir: dir} do
      File.write!(Path.join(dir, "picked"), "cards")

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      view |> element("#approve-design") |> render_click()

      assert has_element?(view, "#design-error", "no screenshot yet")
    end

    test "picking while the designer works says so", %{conn: conn, task: task, design_run: design_run} do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      {:ok, _working} = Pipeline.update_run(design_run, %{status: :running})
      view |> element("#pick-design-cards") |> render_click()

      assert has_element?(view, "#design-error", "still running")
    end

    # Each of these is a state that arrived after the button was drawn, which is
    # the only way a person gets to press one of them at all.
    test "a pick that has gone stale says what is wrong rather than nothing", %{
      conn: conn,
      task: task,
      design_dir: dir
    } do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      # Somebody else picked while this was on screen.
      File.write!(Path.join(dir, "picked"), "table")
      view |> element("#pick-design-cards") |> render_click()
      assert has_element?(view, "#design-error", "already been picked")

      # The designer rewrote its options and the one on screen is not among them.
      File.rm!(Path.join(dir, "picked"))
      File.write!(Path.join(dir, "manifest.json"), Jason.encode!(%{"options" => [%{"key" => "table", "title" => "T"}]}))
      view |> element("#pick-design-cards") |> render_click()
      assert has_element?(view, "#design-error", "no longer exists")

      # The designer withdrew its options altogether.
      File.rm!(Path.join(dir, "manifest.json"))
      view |> element("#pick-design-cards") |> render_click()
      assert has_element?(view, "#design-error", "not written any options yet")
    end

    test "approving with nothing picked, or a picture older than the design, says so", %{
      conn: conn,
      task: task,
      design_dir: dir
    } do
      File.write!(Path.join(dir, "picked"), "cards")
      File.write!(Path.join(dir, "cards.png"), "png bytes")

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      # A screenshot older than the design it is of is a picture of something
      # else.
      old = DateTime.utc_now() |> DateTime.shift(hour: -1) |> DateTime.to_unix()
      File.touch!(Path.join(dir, "cards.png"), old)

      view |> element("#approve-design") |> render_click()
      assert has_element?(view, "#design-error", "older than the design")

      File.rm!(Path.join(dir, "picked"))
      view |> element("#approve-design") |> render_click()
      assert has_element?(view, "#design-error", "Pick a design before approving it.")
    end

    # A designer that has not said anything yet cannot be answered, and pressing
    # a button that was drawn before it stopped says so.
    test "a design run with no conversation cannot be picked from", %{
      conn: conn,
      task: task,
      design_run: design_run
    } do
      {:ok, _silent} = Pipeline.update_run(design_run, %{conversation_id: nil})

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      view |> element("#pick-design-cards") |> render_click()

      assert has_element?(view, "#design-error", "cannot be messaged yet")
    end

    # A manifest that lists nothing has nothing to select, and the pane says the
    # designer has written nothing rather than opening an empty option.
    test "a manifest listing nothing reads as nothing written", %{conn: conn, task: task, design_dir: dir} do
      File.write!(Path.join(dir, "manifest.json"), Jason.encode!(%{"options" => []}))

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "[data-qa='design_pending']")
    end

    test "a task that moved on under the reader cannot be picked from", %{conn: conn, task: task} do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      {:ok, _moved} = Pipeline.update_task(task, %{stage: :architect})

      view |> element("#pick-design-cards") |> render_click()

      assert has_element?(view, "#design-error", "This task is at Architect, not design.")
    end
  end

  describe "the architect stage" do
    setup %{project: project, task: task} do
      roles =
        Map.new([:architect, :engineer], fn stage ->
          {:ok, role} = Roles.get_role(project_id: project.id, stage: stage)

          {stage, role}
        end)

      {:ok, task} = Pipeline.update_task(task, %{stage: :architect, worktree_path: create_temp_git_repo()})

      {:ok, architect_run} =
        Pipeline.create_run(%{
          task_id: task.id,
          role_id: roles[:architect].id,
          status: :finished,
          stage_outcome: :done,
          conversation_id: "sess_architect_stage",
          started_at: DateTime.utc_now()
        })

      plans_dir = Path.join(task.scratch_path, "plans")
      File.mkdir_p!(plans_dir)
      plan_path = Path.join(plans_dir, "TLV-1.md")
      File.write!(plan_path, "## Implementation plan\n\n### Approach\nExtend the invoices module.\n")

      %{task: task, roles: roles, architect_run: architect_run, plan_path: plan_path}
    end

    test "renders the plan the architect wrote", %{conn: conn, task: task} do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "#architect-plan", "Extend the invoices module.")
      assert has_element?(view, "#approve-plan")
    end

    test "says so when the architect has written nothing", %{conn: conn, task: task, plan_path: path} do
      File.rm!(path)

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "[data-qa='architect_plan_pending']")
      assert has_element?(view, "#architect-plan-pending-title", "No plan yet")
      refute has_element?(view, "#approve-plan")
    end

    test "says the architect is at work while it is", %{
      conn: conn,
      task: task,
      architect_run: architect_run,
      plan_path: path
    } do
      File.rm!(path)
      {:ok, _working} = Pipeline.update_run(architect_run, %{status: :running})

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "#architect-plan-pending-title", "Planning the implementation")
    end

    # The architect rewrites the file in place, so a finished turn changes no row.
    test "re-reads the plan when a turn finishes", %{
      conn: conn,
      task: task,
      architect_run: architect_run,
      plan_path: path
    } do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      assert has_element?(view, "#architect-plan", "Extend the invoices module.")

      File.write!(path, "## Implementation plan\n\n### Approach\nExtend the payments module instead.\n")
      send(view.pid, {:os_process_finished, architect_run, %{}})

      # The page forwards to the component, which renders on its own turn.
      _settled = render(view)
      assert has_element?(view, "#architect-plan", "Extend the payments module instead.")
    end

    test "approving the plan hands the task to the engineer", %{conn: conn, task: task, roles: roles} do
      stub(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned, task: task}} end)

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      view |> element("#approve-plan") |> render_click()

      assert %Task{stage: :engineer} = Repo.reload!(task)
      assert Repo.get_by(Run, task_id: task.id, role_id: roles[:engineer].id)
    end

    test "approving while the architect works says why it did not", %{
      conn: conn,
      task: task,
      architect_run: architect_run
    } do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      {:ok, _working} = Pipeline.update_run(architect_run, %{status: :running})
      view |> element("#approve-plan") |> render_click()

      assert has_element?(view, "#architect-error", "still running")
      assert %Task{stage: :architect} = Repo.reload!(task)
    end

    # Both of these arrived after the button was drawn, which is the only way a
    # person gets to press it in either state.
    test "an approval that has gone stale says what is wrong", %{conn: conn, task: task, plan_path: path} do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      File.rm!(path)
      view |> element("#approve-plan") |> render_click()
      assert has_element?(view, "#architect-error", "not written a plan yet")

      File.write!(path, "## Implementation plan\n")
      {:ok, _moved} = Pipeline.update_task(task, %{stage: :engineer})

      view |> element("#approve-plan") |> render_click()
      assert has_element?(view, "#architect-error", "This task is at Engineer, not architect.")
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

      assert %Run{status: :running, ci_failure_streak: 0} = Repo.reload!(run)
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

    test "rebase hands conflicts to the engineer and says it is rebasing", %{
      conn: conn,
      task: task,
      engineer_run: run
    } do
      expect(Git, :fetch_default_branch, fn _project, _path -> :ok end)
      expect(Git, :rebase_branch, fn _scope, _task -> {:conflicts, ["shipped.ex"]} end)

      expect(Tools, :start_os_process, fn spawned, ["-p", prompt | _rest] ->
        assert prompt =~ "- shipped.ex"
        {:ok, %OsProcess{run: spawned}}
      end)

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      assert has_element?(view, "#rebase-task[title='Rebase onto origin/main']", "Rebase")

      view |> element("#rebase-task") |> render_click()

      assert_patch(view, ~p"/tasks/#{task.id}?tab=#{run.role_id}")
      assert %Task{is_rebasing: true} = Repo.reload!(task)
      assert %Run{status: :running} = Repo.reload!(run)
      assert has_element?(view, "#rebase-task[disabled]", "Rebasing…")
    end

    test "rebase says why for each way it can be refused", %{conn: conn, task: task, engineer_run: run, repo: repo} do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      expect(Git, :fetch_default_branch, fn _project, _path -> {:error, "could not read from remote"} end)
      view |> element("#rebase-task") |> render_click()
      assert render(view) =~ "Could not rebase: could not read from remote"

      expect(Git, :fetch_default_branch, fn _project, _path -> :ok end)
      expect(Git, :rebase_branch, fn _scope, _task -> {:conflicts, ["shipped.ex"]} end)
      expect(Tools, :start_os_process, fn _spawned, _argv -> {:error, :dispatch_disabled} end)
      view |> element("#rebase-task") |> render_click()
      assert render(view) =~ "Could not rebase: :dispatch_disabled"

      {:ok, running} = Pipeline.update_run(Repo.reload!(run), %{status: :running})
      render_click(view, "rebase", %{})
      assert render(view) =~ "Stop the task&#39;s run before rebasing it"

      {:ok, _idle} = Pipeline.update_run(running, %{status: :finished})
      File.rm_rf!(repo)
      render_click(view, "rebase", %{})
      assert render(view) =~ "The task&#39;s worktree is gone, so there is nothing to rebase"
    end

    test "rebase says why when the branch cannot be handed back", %{conn: conn, task: task, repo: repo} do
      File.write!(Path.join(repo, "wip.ex"), "uncommitted\n")

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      view |> element("#rebase-task") |> render_click()

      assert render(view) =~ "Commit the engineer&#39;s work before rebasing it"
    end

    test "a task past engineer offers review again for what the engineer changed since", %{
      conn: conn,
      task: task,
      role: role
    } do
      {:ok, _moved} = Pipeline.update_task(task, %{stage: :demo})

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}?tab=#{role.id}")
      assert has_element?(view, "#send-to-review")
    end

    test "a task past engineer with nothing new is not offered review again", %{
      conn: conn,
      project: project,
      task: task,
      role: role,
      repo: repo
    } do
      {:ok, review_role} = Roles.get_role(project_id: project.id, stage: :review)

      {:ok, _review_run} =
        Pipeline.create_run(%{
          task_id: task.id,
          role_id: review_role.id,
          status: :finished,
          stage_outcome: :done,
          stage_fingerprint_head_sha: String.trim(git!(repo, ["rev-parse", "HEAD"])),
          started_at: DateTime.utc_now()
        })

      {:ok, _moved} = Pipeline.update_task(task, %{stage: :demo})

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}?tab=#{role.id}")
      refute has_element?(view, "#send-to-review")

      view |> with_target("#engineer-stage") |> render_click("send_to_review", %{})
      assert has_element?(view, "#engineer-error", "Review has already seen this commit.")
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

      view |> element("#commit-work") |> render_click()
      render_async(view, 5_000)

      refute has_element?(view, "#commit-work")
      assert %Run{error: nil} = Repo.reload!(run)
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

    # A turn that ended badly leaves the worktree dirty, and the task can already
    # have moved on by the time anyone looks. Withholding the button there leaves
    # work that nothing can commit.
    test "the commit is still offered once the task has moved past engineer", %{conn: conn, task: task, repo: repo} do
      File.write!(Path.join(repo, "left_behind.ex"), "uncommitted\n")
      {:ok, _moved} = Pipeline.update_task(task, %{stage: :review})

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "#commit-work")
    end

    test "sending the diff to review moves the task", %{conn: conn, task: task} do
      stub(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned, task: task}} end)

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      view |> element("#send-to-review") |> render_click()

      assert %Task{stage: :review} = Repo.reload!(task)
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
  end

  describe "the conversation, which the page hosts and feeds" do
    setup %{project: project, task: task, run: run} do
      {:ok, other_role} = Roles.get_role(project_id: project.id, stage: :design)

      {:ok, other_run} =
        Pipeline.create_run(%{
          task_id: task.id,
          role_id: other_role.id,
          status: :finished,
          conversation_id: "sess_design",
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
      assert has_element?(view, "#metadata-run-conversation-id", "sess_design")

      send(view.pid, :task_changed)
      assert has_element?(view, "#metadata-run-conversation-id", "sess_design")
    end

    test "moving to the next stage moves the conversation to that stage's run", %{conn: conn, task: task} do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      assert has_element?(view, "#metadata-run-conversation-id", "sess_product")

      {:ok, _moved} = Pipeline.update_task(task, %{stage: :design})
      send(view.pid, :task_changed)

      assert has_element?(view, "#metadata-run-conversation-id", "sess_design")
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
      assert has_element?(view, "[data-qa='product_ticket']", "The first draft.")

      File.write!(ticket_path, "# A ticket\n\nThe revised draft.")
      send(view.pid, {:os_process_finished, run, %{}})

      # The page forwards to the component, which renders on its own turn.
      _settled = render(view)
      assert has_element?(view, "[data-qa='product_ticket']", "The revised draft.")
    end
  end

  describe "the review stage" do
    setup %{project: project, task: task} do
      {:ok, role} = Roles.get_role(project_id: project.id, stage: :review)

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

      raised = [
        %{
          key: "unhandled-nil",
          title: "Nil is not handled",
          detail: "The clause assumes a map.",
          file: "lib/rail/example.ex",
          line: 12,
          severity: :blocker,
          recommendation: :fix,
          status: :open
        },
        %{key: "naming-nit", title: "Poor variable name", severity: :nit, recommendation: :skip, status: :open}
      ]

      # Nothing is decided until a person decides it, so a test that is not about
      # deciding rules the way the reviewer advised and changes only its own bit.
      decide_as_advised = fn ->
        {:ok, findings} = Pipeline.sync_review_findings(task, raised)

        Enum.map(findings, fn finding ->
          {:ok, decided} = Pipeline.decide_review_finding(finding, finding.recommendation)
          decided
        end)
      end

      %{
        task: task,
        role: role,
        review_run: review_run,
        raised: raised,
        decide_as_advised: decide_as_advised
      }
    end

    test "lists every finding, worst first, with where it is", %{
      conn: conn,
      task: task,
      decide_as_advised: decide_as_advised
    } do
      _decided = decide_as_advised.()

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "#review-findings")
      assert has_element?(view, "#finding-unhandled-nil", "Nil is not handled")
      assert has_element?(view, "#finding-naming-nit", "Poor variable name")
      assert has_element?(view, "[data-qa='review_finding_tally']", "1 to fix · 1 dismissed")
    end

    test "the worst finding is the one open in the reading pane", %{
      conn: conn,
      task: task,
      decide_as_advised: decide_as_advised
    } do
      _decided = decide_as_advised.()

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "[data-qa='review_finding_detail']", "Nil is not handled")
      assert has_element?(view, "[data-qa='finding_position']", "1 of 2")
      assert has_element?(view, "[data-qa='finding_location']", "lib/rail/example.ex:12")
      assert has_element?(view, "[data-qa='finding_recommendation']", "recommends fixing this")
    end

    test "picking a finding reads it", %{conn: conn, task: task, decide_as_advised: decide_as_advised} do
      _decided = decide_as_advised.()

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      view |> element("#finding-naming-nit") |> render_click()

      assert has_element?(view, "[data-qa='review_finding_detail']", "Poor variable name")
      assert has_element?(view, "[data-qa='finding_position']", "2 of 2")
      assert has_element?(view, "[data-qa='finding_dismissed']", "Dismissed")
      assert has_element?(view, "[data-qa='finding_recommendation']", "recommends leaving this")
    end

    test "the reader walks the findings without going back to the list", %{
      conn: conn,
      task: task,
      decide_as_advised: decide_as_advised
    } do
      _decided = decide_as_advised.()

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      assert has_element?(view, "#finding-previous[disabled]")

      view |> element("#finding-next") |> render_click()

      assert has_element?(view, "[data-qa='review_finding_detail']", "Poor variable name")
      assert has_element?(view, "#finding-next[disabled]")

      view |> element("#finding-previous") |> render_click()

      assert has_element?(view, "[data-qa='review_finding_detail']", "Nil is not handled")
    end

    # A finding names a line; the change it points at lives on the engineer's tab,
    # so the panel shows the one hunk and links to the rest.
    test "a finding shows the change it points at and links to the whole diff", %{
      conn: conn,
      task: task,
      raised: raised
    } do
      File.mkdir_p!(Path.join(task.worktree_path, "lib/rail"))

      File.write!(
        Path.join(task.worktree_path, "lib/rail/example.ex"),
        Enum.map_join(1..20, "", &"line #{&1}\n")
      )

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

      {:ok, _synced} = Pipeline.sync_review_findings(task, raised)

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "[data-qa='finding_diff']", "lib/rail/example.ex")
      assert has_element?(view, "[data-qa='diff_line_row']", "the line the finding points at")
      assert has_element?(view, "#finding-open-in-diff", "Open diff")
    end

    test "the suggested fix is set apart from the reasoning", %{conn: conn, task: task, raised: raised} do
      {:ok, _synced} =
        Pipeline.sync_review_findings(
          task,
          List.update_at(raised, 0, &Map.put(&1, :suggestion, "Match the empty map first."))
        )

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "[data-qa='finding_suggestion']", "Suggested fix")
      assert has_element?(view, "[data-qa='finding_suggestion']", "Match the empty map first.")
    end

    test "a finding the reviewer checked again shows as fixed", %{conn: conn, task: task, raised: raised} do
      {:ok, _synced} = Pipeline.sync_review_findings(task, List.update_at(raised, 0, &%{&1 | status: :fixed}))

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      # A finished finding is nobody's to rule on, so it sits under what is, and
      # reading it is something the human asks for.
      view |> element("#finding-unhandled-nil") |> render_click()

      assert has_element?(view, "[data-qa='finding_fixed']", "Fixed")
      assert has_element?(view, "[data-qa='review_finding'][data-state='fixed']")
    end

    test "a finding the engineer did not fix says so", %{
      conn: conn,
      task: task,
      raised: raised,
      decide_as_advised: decide_as_advised
    } do
      _decided = decide_as_advised.()

      # The later pass keeps the ruling and only restates what it found.
      {:ok, _synced} = Pipeline.sync_review_findings(task, List.update_at(raised, 0, &%{&1 | status: :not_fixed}))

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "[data-qa='finding_not_fixed']", "Still not fixed")
      assert has_element?(view, "#send-findings-to-engineer")
    end

    test "the human overrules a recommendation from the reading pane", %{
      conn: conn,
      task: task,
      decide_as_advised: decide_as_advised
    } do
      _decided = decide_as_advised.()

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      assert has_element?(view, "[data-qa='review_finding'][data-state='to_fix']", "Nil is not handled")

      view |> element("#decide-skip-unhandled-nil") |> render_click()

      assert has_element?(view, "[data-qa='review_finding'][data-state='dismissed']", "Nil is not handled")
      assert has_element?(view, "[data-qa='finding_recommendation']", "You dismissed it.")
      assert has_element?(view, "[data-qa='review_finding_tally']", "2 dismissed")
    end

    test "the human takes on a finding the reviewer would have left", %{
      conn: conn,
      task: task,
      decide_as_advised: decide_as_advised
    } do
      _decided = decide_as_advised.()

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      view |> element("#finding-naming-nit") |> render_click()
      view |> element("#decide-fix-naming-nit") |> render_click()

      assert has_element?(view, "[data-qa='finding_recommendation']", "You chose to fix it.")
      assert has_element?(view, "#send-findings-to-engineer", "Send 2 back to engineer")
    end

    test "outstanding findings go back to the engineer", %{conn: conn, task: task, decide_as_advised: decide_as_advised} do
      _decided = decide_as_advised.()

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      assert has_element?(view, "#send-findings-to-engineer", "Send 1 back to engineer")
      refute has_element?(view, "#send-to-qa")

      view |> element("#send-findings-to-engineer") |> render_click()

      assert %Task{stage: :engineer} = Repo.reload!(task)
    end

    test "a change with nothing outstanding offers QA instead", %{conn: conn, task: task} do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "#review-pending-title", "Nothing to fix")
      assert has_element?(view, "#send-to-qa")
      refute has_element?(view, "#send-findings-to-engineer")

      view |> element("#send-to-qa") |> render_click()

      assert %Task{stage: :qa} = Repo.reload!(task)
    end

    test "dismissing the last outstanding finding is what opens QA", %{
      conn: conn,
      task: task,
      decide_as_advised: decide_as_advised
    } do
      _decided = decide_as_advised.()

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      refute has_element?(view, "#send-to-qa")

      view |> element("#decide-skip-unhandled-nil") |> render_click()

      assert has_element?(view, "#send-to-qa")
      refute has_element?(view, "#send-findings-to-engineer")
    end

    test "a reviewer still reading offers neither button", %{conn: conn, task: task, review_run: run, raised: raised} do
      {:ok, _synced} = Pipeline.sync_review_findings(task, raised)
      {:ok, _running} = Pipeline.update_run(run, %{status: :running, stage_outcome: :in_progress})

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      refute has_element?(view, "#send-findings-to-engineer")
      refute has_element?(view, "#send-to-qa")
      refute has_element?(view, "[data-qa='decide_fix']")
    end

    test "a reviewer still reading says so rather than showing an empty report", %{
      conn: conn,
      task: task,
      review_run: run
    } do
      {:ok, _running} = Pipeline.update_run(run, %{status: :running, stage_outcome: :in_progress})

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "#review-pending-title", "Reading the change")
      refute has_element?(view, "#send-to-qa")
    end

    # A run that stopped without reporting and one that reported nothing look the
    # same on the page, and only one of them is a change anybody should send on.
    test "a reviewer that stopped without reporting does not read as a clean review", %{
      conn: conn,
      task: task,
      review_run: run
    } do
      {:ok, _stopped} = Pipeline.update_run(run, %{status: :finished, stage_outcome: :in_progress})

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "#review-pending-title", "No findings yet")
      refute has_element?(view, "#send-to-qa")
    end

    test "a finding raised underneath the page stops it going to QA", %{conn: conn, task: task, raised: raised} do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      assert has_element?(view, "#send-to-qa")

      {:ok, _synced} = Pipeline.sync_review_findings(task, raised)
      view |> element("#send-to-qa") |> render_click()

      assert has_element?(view, "#review-error", "no decision yet")
      assert %Task{stage: :review} = Repo.reload!(task)
    end

    test "findings dismissed underneath the page leave nothing to send back", %{
      conn: conn,
      task: task,
      decide_as_advised: decide_as_advised
    } do
      findings = decide_as_advised.()

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      for finding <- findings, do: {:ok, _dismissed} = Pipeline.decide_review_finding(finding, :skip)
      view |> element("#send-findings-to-engineer") |> render_click()

      assert has_element?(view, "#review-error", "nothing left for the engineer to fix")
    end

    test "a run started underneath the page holds the decision", %{
      conn: conn,
      task: task,
      review_run: run,
      raised: raised
    } do
      {:ok, _synced} = Pipeline.sync_review_findings(task, raised)

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      {:ok, _running} = Pipeline.update_run(run, %{status: :running})
      view |> element("#decide-skip-unhandled-nil") |> render_click()

      assert has_element?(view, "#review-error", "still running on this task")
    end

    test "a task moved on underneath the page says where it went", %{conn: conn, task: task} do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      {:ok, _moved} = Pipeline.update_task(task, %{stage: :qa})
      view |> element("#send-to-qa") |> render_click()

      assert has_element?(view, "#review-error", "This task is at QA, not review.")
    end

    # Only a window around the line the finding names is shown, so the pane has
    # to say what it left out rather than let the reader take it for the whole
    # change.
    test "a hunk says what it left out", %{conn: conn, task: task} do
      File.mkdir_p!(Path.join(task.worktree_path, "lib/rail"))
      before = Enum.map_join(1..80, "", &"line #{&1}\n")
      File.write!(Path.join(task.worktree_path, "lib/rail/example.ex"), before)
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

      {:ok, _synced} =
        Pipeline.sync_review_findings(task, [
          %{
            key: "long-hunk",
            title: "A long change",
            file: "lib/rail/example.ex",
            line: 20,
            severity: :major,
            recommendation: :fix,
            status: :open
          }
        ])

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "[data-qa='finding_other_hunks']", "more lines")
      assert has_element?(view, "[data-qa='finding_other_hunks']", "1 more other change")
    end

    # Severity is the first thing a reader takes off the list, so every grade has
    # to be distinguishable - and a finding with no line, or no file at all, is
    # still a finding.
    test "each grade of finding reads as itself, wherever it is", %{conn: conn, task: task} do
      {:ok, _synced} =
        Pipeline.sync_review_findings(task, [
          %{key: "a-major", title: "A major", file: "lib/a.ex", severity: :major, recommendation: :fix},
          %{key: "a-minor", title: "A minor", severity: :minor, recommendation: :fix},
          %{key: "a-nit", title: "A nit", file: "lib/b.ex", line: 3, severity: :nit, recommendation: :skip},
          %{key: "was-fixed", title: "Fixed since", severity: :major, recommendation: :fix, status: :fixed}
        ])

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "#finding-a-major", "lib/a.ex")
      assert has_element?(view, "#finding-a-minor", "no file")
      # A finding checked again and found fixed says so instead of where it was,
      # and one with nowhere to point has nowhere to print.
      assert has_element?(view, "#finding-was-fixed", "fixed ·")

      view |> element("#finding-a-minor") |> render_click()
      assert has_element?(view, "[data-qa='review_finding_detail']", "Minor")

      view |> element("#finding-a-major") |> render_click()
      assert has_element?(view, "[data-qa='review_finding_detail']", "Major")
      assert has_element?(view, "[data-qa='finding_location']", "lib/a.ex")
    end

    # The button was drawn when nothing was outstanding, and something became
    # outstanding while the reader was looking at it.
    test "a finding put back underneath the page stops it going to QA", %{conn: conn, task: task, raised: raised} do
      {:ok, findings} = Pipeline.sync_review_findings(task, raised)
      Enum.each(findings, fn finding -> {:ok, _skipped} = Pipeline.decide_review_finding(finding, :skip) end)

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      assert has_element?(view, "#send-to-qa")

      [kept | _rest] = Pipeline.list_review_findings(task)
      {:ok, _kept} = Pipeline.decide_review_finding(kept, :fix)

      view |> element("#send-to-qa") |> render_click()

      assert has_element?(view, "#review-error", "still outstanding")
    end

    test "a turn finishing re-reads the findings it just recorded", %{
      conn: conn,
      task: task,
      review_run: run,
      raised: raised
    } do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      assert has_element?(view, "#review-pending-title", "Nothing to fix")

      {:ok, _synced} = Pipeline.sync_review_findings(task, raised)
      send(view.pid, {:os_process_finished, run, %{}})

      _settled = render(view)
      assert has_element?(view, "[data-qa='review_finding_detail']", "Nil is not handled")
    end
  end

  describe "the qa stage" do
    setup %{project: project, task: task} do
      {:ok, role} = Roles.get_role(project_id: project.id, stage: :qa)

      {:ok, engineer_role} = Roles.get_role(project_id: project.id, stage: :engineer)

      {:ok, task} = Pipeline.update_task(task, %{stage: :qa, worktree_path: create_temp_git_repo()})

      {:ok, _engineer_run} =
        Pipeline.create_run(%{
          task_id: task.id,
          role_id: engineer_role.id,
          status: :finished,
          stage_outcome: :done,
          conversation_id: "sess_qa_stage_engineer",
          started_at: DateTime.utc_now()
        })

      {:ok, qa_run} =
        Pipeline.create_run(%{
          task_id: task.id,
          role_id: role.id,
          status: :finished,
          stage_outcome: :done,
          conversation_id: "sess_qa_stage",
          started_at: DateTime.utc_now()
        })

      qa_dir = Path.join(task.scratch_path, "qa")
      File.mkdir_p!(Path.join(qa_dir, "evidence"))
      File.write!(Path.join([qa_dir, "evidence", "total.png"]), "png bytes")

      File.write!(Path.join(qa_dir, "TLV-1.json"), """
      {"verdict": "fail",
       "summary": "The bill saves but its total is wrong.",
       "not_checked": "The Plaid callback, which needs a real bank.",
       "findings": []}
      """)

      raised = [
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
          severity: :blocker,
          recommendation: :fix,
          status: :open,
          evidence: [%{name: "the total as rendered", kind: :screenshot, path: "evidence/total.png"}]
        },
        %{
          key: "spacing-nit",
          title: "Buttons sit too close together",
          check: "The bill form looks like the rest of the app",
          severity: :nit,
          recommendation: :skip,
          status: :open,
          caused_by_change: false
        }
      ]

      # Nothing is decided until a person decides it, so a test that is not about
      # deciding rules the way QA advised and changes only its own bit.
      decide_as_advised = fn ->
        {:ok, findings} = Pipeline.sync_qa_findings(task, raised)

        Enum.map(findings, fn finding ->
          {:ok, decided} = Pipeline.decide_qa_finding(finding, finding.recommendation)
          decided
        end)
      end

      %{task: task, role: role, qa_run: qa_run, raised: raised, decide_as_advised: decide_as_advised}
    end

    test "lists every finding with QA's verdict over the top", %{
      conn: conn,
      task: task,
      decide_as_advised: decide_as_advised
    } do
      _decided = decide_as_advised.()

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "#qa-sidebar")
      assert has_element?(view, "[data-qa='qa_verdict_label']", "Failed")
      assert has_element?(view, "[data-qa='qa_verdict']", "The bill saves but its total is wrong.")
      assert has_element?(view, "#qa-finding-total-unrounded", "The bill total renders as $1234.5")
      assert has_element?(view, "#qa-finding-spacing-nit", "Buttons sit too close together")

      # The verdict is the first row of that list rather than a banner over it,
      # so the rest of what QA made of the change opens where a finding does.
      refute has_element?(view, "[data-qa='qa_not_checked']")

      view |> element("#qa-verdict") |> render_click()

      assert has_element?(view, "#qa-report-detail [data-qa='qa_not_checked']", "The Plaid callback")
      refute has_element?(view, "[data-qa='qa_finding_detail']")

      # Nothing closes the verdict: picking the next thing to read is what
      # leaves it, the same as every other row of that list.
      refute has_element?(view, "#qa-report-detail [data-qa='qa_close_pane']")

      view |> element("#qa-finding-total-unrounded") |> render_click()

      refute has_element?(view, "#qa-report-detail")
      assert has_element?(view, "[data-qa='qa_finding_detail']", "The bill total renders as $1234.5")
    end

    test "the detail pane says what QA drove and what it saw", %{
      conn: conn,
      task: task,
      decide_as_advised: decide_as_advised
    } do
      _decided = decide_as_advised.()

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "[data-qa='qa_finding_detail']", "The bill total renders as $1234.5")
      assert has_element?(view, "[data-qa='qa_finding_position']", "1 of 2")
      assert has_element?(view, "[data-qa='qa_finding_screen']", "/bills/new")
      assert has_element?(view, "[data-qa='qa_finding_criterion']", "Totals read as money")
      assert has_element?(view, "[data-qa='qa_finding_check']", "A bill's total reads as money")
      assert has_element?(view, "[data-qa='qa_finding_steps']", "Enter 1234.50")
      assert has_element?(view, "[data-qa='qa_finding_expected']", "$1,234.50")
      assert has_element?(view, "[data-qa='qa_finding_observed']", "$1234.5")
      assert has_element?(view, "[data-qa='qa_finding_suggestion']", "Money.to_string/1")
      assert has_element?(view, "[data-qa='qa_finding_recommendation']", "recommends fixing this")
    end

    test "a screenshot is shown rather than described", %{
      conn: conn,
      task: task,
      decide_as_advised: decide_as_advised
    } do
      _decided = decide_as_advised.()

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(
               view,
               ~s(img[src="/tasks/#{task.id}/qa/total-unrounded/evidence/0"][alt="the total as rendered"])
             )
    end

    test "what this change did not cause is marked and sorted below what it did", %{
      conn: conn,
      task: task,
      decide_as_advised: decide_as_advised
    } do
      _decided = decide_as_advised.()

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      view |> element("#qa-finding-spacing-nit") |> render_click()

      assert has_element?(view, "[data-qa='qa_finding_pre_existing']", "Not this change")
      assert has_element?(view, "[data-qa='qa_finding_dismissed']", "Dismissed")
    end

    test "a pass that raised nothing says so", %{conn: conn, task: task} do
      {:ok, _raised} = Pipeline.sync_qa_findings(task, [])

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "#qa-pending-title", "Nothing to fix")
    end

    test "a finding is ruled on from the detail pane", %{conn: conn, task: task, decide_as_advised: decide_as_advised} do
      _decided = decide_as_advised.()

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      view |> element("#decide-skip-total-unrounded") |> render_click()

      assert has_element?(view, "[data-qa='qa_finding_dismissed']", "Dismissed")
      assert has_element?(view, "[data-qa='qa_finding_recommendation']", "You dismissed it")
    end

    test "nothing can be sent while a finding has no ruling on it", %{conn: conn, task: task, raised: raised} do
      {:ok, _undecided} = Pipeline.sync_qa_findings(task, raised)

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "[data-qa='qa_finding_undecided']", "Needs your call")
      refute has_element?(view, "#send-qa-findings-to-engineer")
      refute has_element?(view, "#send-to-demo")
    end

    test "what the human kept goes back to the engineer", %{conn: conn, task: task, decide_as_advised: decide_as_advised} do
      _decided = decide_as_advised.()
      stub(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned, task: task}} end)

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      view |> element("#send-qa-findings-to-engineer", "Send 1 back to engineer") |> render_click()

      assert %Task{stage: :engineer} = Repo.reload!(task)
    end

    test "a change with nothing left goes on to demo", %{conn: conn, task: task, decide_as_advised: decide_as_advised} do
      for finding <- decide_as_advised.(), do: {:ok, _dismissed} = Pipeline.decide_qa_finding(finding, :skip)

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      refute has_element?(view, "#send-qa-findings-to-engineer")
      view |> element("#send-to-demo") |> render_click()

      assert %Task{stage: :demo} = Repo.reload!(task)
    end

    test "a refusal is shown rather than swallowed", %{conn: conn, task: task, decide_as_advised: decide_as_advised} do
      _decided = decide_as_advised.()

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      {:ok, _moved} = Pipeline.update_task(task, %{stage: :review})
      view |> element("#send-qa-findings-to-engineer") |> render_click()

      assert has_element?(view, "#qa-error", "This task is at Review, not QA.")
    end

    # A stopped QA agent and one that exercised the change and found nothing look
    # identical otherwise, and only one of them is a change anybody should send on.
    test "a QA run that never reported is not a clean pass", %{conn: conn, task: task, qa_run: run} do
      {:ok, _unlatched} = Pipeline.update_run(run, %{stage_outcome: :in_progress})

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "#qa-pending-title", "No findings yet")
      refute has_element?(view, "#send-to-demo")
    end

    # A pass in flight has no findings to read yet, so what is shown is what it is
    # doing: the checklist it wrote before it opened anything, beside the browser.
    test "a QA pass still running shows the checklist and the browser", %{conn: conn, task: task, qa_run: run} do
      {:ok, _running} = Pipeline.update_run(run, %{status: :running, stage_outcome: :in_progress})

      {:ok, _checklist} =
        Pipeline.write_qa_checklist(task, [
          %{"key" => "bill-saves", "title" => "A bill saves and survives a reload", "group" => "Setup"},
          %{"key" => "totals", "title" => "The total agrees with the journal entry", "group" => "Acceptance"}
        ])

      {:ok, _marked} = Pipeline.record_qa_check(task, "bill-saves", "pass", "saved to the cent")

      # What the pass did reads as a sequence of actions: the word for each one is
      # lifted out of the line, and the ones worth stopping at - a refusal, a
      # step Rail took rather than was given - are set apart from the rest.
      _logged =
        Pipeline.append_run_events(run.id, nil, [
          "[browser] look",
          "[qa] plan 3 checks",
          "[browser]   CLICK \"Save changes\"",
          "[browser] REFUSED \"Save changes\" is covered",
          "[browser] goto http://localhost:4000/bills/new",
          "[browser]   click \"Save\""
        ])

      File.write!(Path.join([task.scratch_path, "qa", "evidence", "totals~the-journal-entry.png"]), "png bytes")

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "#qa-running", "Driving the application")
      assert has_element?(view, "#qa-screencast")
      assert has_element?(view, "[data-qa='qa_screencast_waiting']")

      # Where the browser is, and the last thing Rail actually did to it.
      assert has_element?(view, "[data-qa='qa_browser_url']", "localhost:4000/bills/new")
      assert has_element?(view, "[data-qa='qa_doing']", "click")
      assert has_element?(view, "[data-qa='qa_doing']", "Save")

      # A line with nothing after the verb is all verb, a step Rail took is set
      # apart from the instruction it came from, and a refusal is the one of
      # these a reader should stop at.
      assert has_element?(view, "[data-qa='driving-verb']", "look")
      assert has_element?(view, "[data-qa='driving-verb']", "plan")
      assert has_element?(view, "[data-qa='driving-step'][data-step='step']", "CLICK")
      assert has_element?(view, "[data-qa='driving-verb'].bg-amber-100", "REFUSED")

      # The pictures taken for the row it is on.
      assert has_element?(view, "[data-qa='qa_current_shot']", "The journal entry")

      view |> element("[data-qa='qa_current_shot']") |> render_click()

      assert has_element?(view, "#qa-shot-viewer [data-qa='qa_shot_name']", "The journal entry")
      assert has_element?(view, "[data-qa='qa_checklist_progress']", "1 of 2")
      assert has_element?(view, "[data-qa='qa_check'][data-key='bill-saves'][data-outcome='pass']")

      # The row says how it went and no more: what the pass wrote about it is a
      # sentence or a paragraph, and forty of those is a column nobody can scan.
      assert has_element?(view, "[data-qa='qa_check_note']", "passed")
      refute has_element?(view, "[data-qa='qa_check_note']", "saved to the cent")
      assert has_element?(view, "[data-qa='qa_check'][data-key='totals'][data-outcome='pending']")

      # The headings the pass chose, and the row it is on.
      assert has_element?(view, "[data-qa='qa_check_group']", "Setup")
      assert has_element?(view, "[data-qa='qa_check_group']", "Acceptance")
      assert has_element?(view, "[data-qa='qa_check'][data-key='totals'][data-current='true']")
      assert has_element?(view, "[data-qa='qa_checklist_tally']", "1 passed")
      assert has_element?(view, "[data-qa='qa_checklist_tally']", "1 left")
    end

    # A row that went green is a claim, and the picture filed against it is what
    # makes it checkable. They sit on the row rather than in one pile.
    test "a checklist row opens with the pictures taken for it", %{conn: conn, task: task} do
      {:ok, _synced} =
        Pipeline.sync_qa_findings(task, [
          %{key: "a-nit", title: "A nit", check: "check", severity: :nit, recommendation: :skip}
        ])

      {:ok, _checklist} =
        Pipeline.write_qa_checklist(task, [
          %{
            "key" => "bill-saves",
            "title" => "A bill saves and survives a reload",
            "group" => "Setup",
            "criterion" => "A bill can be entered and saved"
          },
          %{"key" => "totals", "title" => "The total agrees with the journal entry"}
        ])

      {:ok, _marked} = Pipeline.record_qa_check(task, "bill-saves", "pass", "saved to the cent")

      File.write!(Path.join([task.scratch_path, "qa", "evidence", "bill-saves~the-saved-bill.png"]), "png bytes")

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      # The findings and the checklist share one sidebar, so a reader who has
      # read a finding can still see what was checked.
      assert has_element?(view, "#qa-sidebar #qa-finding-list")
      assert has_element?(view, "#qa-sidebar #qa-checklist")

      assert has_element?(view, "[data-qa='qa_check'][data-key='bill-saves'] [data-qa='qa_check_shots']", "1")
      refute has_element?(view, "[data-qa='qa_check'][data-key='totals'] [data-qa='qa_check_shots']")

      view |> element("#qa-check-bill-saves") |> render_click()

      assert has_element?(view, "#qa-check-detail", "A bill saves and survives a reload")
      assert has_element?(view, "[data-qa='qa_check_detail_group']", "Setup")
      assert has_element?(view, "[data-qa='qa_check_detail_note']", "saved to the cent")
      assert has_element?(view, "[data-qa='qa_check_detail_criterion']", "A bill can be entered and saved")
      assert has_element?(view, "[data-qa='qa_check_detail_note']", "saved to the cent")

      assert has_element?(
               view,
               ~s(#qa-check-detail img[src="/tasks/#{task.id}/qa/evidence/bill-saves~the-saved-bill.png"])
             )

      # A picture opened off a row goes back to the row rather than out of it.
      view |> element("#qa-check-shot-bill-saves-the-saved-bill") |> render_click()

      assert has_element?(view, "#qa-shot-viewer [data-qa='qa_shot_name']", "The saved bill")

      view |> element("#qa-close-pane") |> render_click()

      assert has_element?(view, "#qa-check-detail", "A bill saves and survives a reload")

      view |> element("#qa-check-totals") |> render_click()

      assert has_element?(view, "[data-qa='qa_check_detail_shots']", "Nothing was filed against this row")

      # A row reads on its own; picking the next thing to read is how you leave
      # it, and only a picture has a way out of its own.
      refute has_element?(view, "#qa-check-detail [data-qa='qa_close_pane']")

      view |> element("#qa-finding-a-nit") |> render_click()

      assert has_element?(view, "[data-qa='qa_finding_detail']", "A nit")
    end

    # The first minute of a pass, before it has said what it means to do.
    test "a pass that has not written its checklist yet says so", %{conn: conn, task: task, qa_run: run} do
      {:ok, _running} = Pipeline.update_run(run, %{status: :running, stage_outcome: :in_progress})

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "[data-qa='qa_checklist_progress']", "not written yet")
      assert has_element?(view, "[data-qa='qa_checklist_unwritten']")
    end

    # The checklist moves on disk and nothing else would say so. The pass writes a
    # line in its own log as it marks each row, and that is already carried here.
    test "a row marked off while the panel is open appears", %{conn: conn, task: task, qa_run: run} do
      {:ok, _running} = Pipeline.update_run(run, %{status: :running, stage_outcome: :in_progress})
      {:ok, _checklist} = Pipeline.write_qa_checklist(task, [%{"key" => "totals", "title" => "The totals agree"}])

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      assert has_element?(view, "[data-qa='qa_checklist_progress']", "0 of 1")

      {:ok, _marked} = Pipeline.record_qa_check(task, "totals", "fail", "off by a cent")
      Pipeline.append_run_events(run.id, nil, [~s([qa] check "totals" fail)])

      _settled = render(view)
      assert has_element?(view, "[data-qa='qa_checklist_progress']", "1 of 1")
      assert has_element?(view, "[data-qa='qa_check'][data-key='totals'][data-outcome='fail']")
    end

    # A frame goes to the client rather than through the render, because it
    # arrives several times a second and nothing else on the page moves with it.
    test "a frame from the browser is pushed straight to the client", %{conn: conn, task: task, qa_run: run} do
      {:ok, _running} = Pipeline.update_run(run, %{status: :running, stage_outcome: :in_progress})

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      send(view.pid, {:browser_frame, task.id, "some-base64"})
      _settled = render(view)

      assert_push_event(view, "browser:frame", %{data: "some-base64"})
    end

    # A frame for a task nobody is reading, or while another pane is in front, is
    # nothing to send anywhere.
    test "a frame for another task is ignored", %{conn: conn, task: task} do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      send(view.pid, {:browser_frame, "tsk_somebody_else", "some-base64"})

      assert render(view) =~ "qa"
    end

    # The panel is opened long after the pass ended far more often than during
    # one, and a clean pass is exactly when a reader wants to know what was looked
    # at rather than be told nothing went wrong.
    test "a finished pass still shows what it checked", %{conn: conn, task: task} do
      {:ok, _checklist} =
        Pipeline.write_qa_checklist(task, [%{"key" => "plaid", "title" => "The Plaid callback", "outcome" => "skipped"}])

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "#qa-pending-title", "Nothing to fix")
      assert has_element?(view, "[data-qa='qa_check'][data-key='plaid'][data-outcome='skipped']")
    end

    # A row answered last time round and a finding standing against it are the
    # same pass contradicting itself, and the reader who opens the row is the one
    # who has to see both.
    test "a row carried from an earlier pass shows what was raised against it", %{
      conn: conn,
      task: task
    } do
      plan = [%{"key" => "totals", "title" => "The totals agree", "group" => "Acceptance"}]

      {:ok, _first} = Pipeline.write_qa_checklist(task, plan)
      {:ok, _marked} = Pipeline.record_qa_check(task, "totals", "pass", "agreed to the cent")
      {:ok, _replanned} = Pipeline.write_qa_checklist(task, plan)

      {:ok, _synced} =
        Pipeline.sync_qa_findings(task, [
          %{
            key: "off-by-a-cent",
            title: "The journal entry is off by a cent",
            check: "totals",
            severity: :major,
            recommendation: :fix
          }
        ])

      File.write!(Path.join([task.scratch_path, "qa", "evidence", "totals~the-journal-entry.png"]), "png bytes")

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      # It passed, but not this time round, and the list says which.
      assert has_element?(view, "[data-qa='qa_check'][data-key='totals']", "passed earlier")

      view |> element("[data-qa='qa_check'][data-key='totals']") |> render_click()
      assert has_element?(view, "#qa-check-finding-off-by-a-cent", "off by a cent")
      assert has_element?(view, "[data-qa='qa_check_detail_disagrees']", "only one of them can be right")

      # The finding opens off the row, and the pictures filed for that row come
      # with it - evidence a reader can see beats a paragraph describing it.
      view |> element("#qa-check-finding-off-by-a-cent") |> render_click()
      assert has_element?(view, "[data-qa='qa_finding_check_shots']", "The journal entry")

      # A Close that arrives when the middle is no longer a picture closes to
      # nothing rather than crashing the panel.
      view |> with_target("#qa-stage") |> render_click("close_focus", %{})
      assert has_element?(view, "[data-qa='qa_finding_detail']", "off by a cent")
    end

    # Severity is the first thing a reader takes off the list, so every grade has
    # to be distinguishable, and a fixed finding stops shouting whatever it was
    # raised as.
    test "each grade of finding reads as itself", %{conn: conn, task: task} do
      {:ok, _synced} =
        Pipeline.sync_qa_findings(task, [
          %{key: "a-blocker", title: "A blocker", check: "check", severity: :blocker, recommendation: :fix},
          %{key: "a-major", title: "A major", check: "check", severity: :major, recommendation: :fix},
          %{key: "a-minor", title: "A minor", check: "check", severity: :minor, recommendation: :fix},
          %{key: "a-nit", title: "A nit", check: "check", severity: :nit, recommendation: :skip},
          %{
            key: "already-fixed",
            title: "Fixed last round",
            check: "The bill saves",
            severity: :major,
            recommendation: :fix,
            status: :fixed
          }
        ])

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      for key <- ["a-blocker", "a-major", "a-minor", "a-nit"] do
        assert has_element?(view, "#qa-finding-#{key}")
      end

      assert has_element?(view, "#qa-finding-already-fixed", "fixed · The bill saves")

      view |> element("#qa-finding-a-major") |> render_click()
      assert has_element?(view, "[data-qa='qa_finding_detail']", "Major")

      view |> element("#qa-finding-a-minor") |> render_click()
      assert has_element?(view, "[data-qa='qa_finding_detail']", "Minor")

      # Nothing is left to rule on, so the choice, the remedy and the advice all
      # go and only the record that it was dealt with is left.
      view |> element("#qa-finding-already-fixed") |> render_click()
      assert has_element?(view, "[data-qa='qa_finding_fixed']", "Fixed")
      refute has_element?(view, "[data-qa='qa_finding_recommendation']")
    end

    # A verdict is the one thing a reader wants at a glance, and a pass that wrote
    # a word Rail does not know has still said everything else it said.
    test "every verdict reads as itself, including one Rail cannot place", %{conn: conn, task: task} do
      {:ok, _synced} =
        Pipeline.sync_qa_findings(task, [
          %{key: "a-nit", title: "A nit", check: "check", severity: :nit, recommendation: :skip}
        ])

      report = Path.join([task.scratch_path, "qa", "TLV-1.json"])

      for {written, shown} <- [{"pass", "Passed"}, {"concerns", "Passed with concerns"}, {"sort of", "no verdict"}] do
        File.write!(report, ~s({"verdict": "#{written}", "summary": "What happened.", "findings": []}))

        assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
        assert has_element?(view, "[data-qa='qa_verdict_label']", shown)
      end
    end

    # A queried value is small enough to read where it sits; a captured log is a
    # file, and a file that is not a picture is offered rather than rendered.
    test "evidence that is not a screenshot is read or offered", %{conn: conn, task: task} do
      {:ok, _synced} =
        Pipeline.sync_qa_findings(task, [
          %{
            key: "total-unrounded",
            title: "The total is wrong",
            check: "The total reads as money",
            severity: :major,
            recommendation: :fix,
            evidence: [
              %{name: "what the database holds", kind: :query, text: "amount_cents: 123450"},
              %{name: "the server log", kind: :log, path: "evidence/server.log"}
            ]
          }
        ])

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "[data-qa='qa_evidence'][data-kind='query']", "amount_cents: 123450")
      assert has_element?(view, "[data-qa='qa_evidence_file']", "Open evidence/server.log")
    end

    # QA advises and the human decides, and the panel says so in both directions
    # rather than quietly recording the override.
    test "a finding the human kept against QA's advice says which way that went", %{conn: conn, task: task} do
      {:ok, [nit]} =
        Pipeline.sync_qa_findings(task, [
          %{key: "a-nit", title: "A nit", check: "check", severity: :nit, recommendation: :skip}
        ])

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      assert has_element?(view, "[data-qa='qa_finding_recommendation']", "QA recommends leaving this.")

      view |> element("#decide-fix-#{nit.key}") |> render_click()

      assert has_element?(view, "[data-qa='qa_finding_recommendation']", "QA would have left this.")
    end

    # Every refusal reaches the reader as a sentence rather than as nothing
    # happening. Each of these is a state that arrived after the button was drawn
    # - which is the only way a person gets to click one of these at all.
    test "a send that has gone stale says what is wrong rather than nothing", %{
      conn: conn,
      task: task,
      raised: raised,
      decide_as_advised: decide_as_advised
    } do
      _decided = decide_as_advised.()

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      assert has_element?(view, "#send-qa-findings-to-engineer")

      # A finding raised by a turn that landed while this was on screen has
      # nobody's ruling on it yet.
      late = %{key: "late", title: "Late", check: "c", severity: :nit, recommendation: :skip}
      {:ok, _late} = Pipeline.sync_qa_findings(task, [late | raised])

      view |> element("#send-qa-findings-to-engineer") |> render_click()
      assert has_element?(view, "#qa-error", "no decision yet")

      # Everything dismissed leaves the engineer nothing to do.
      task
      |> Pipeline.list_qa_findings()
      |> Enum.each(fn finding -> {:ok, _skipped} = Pipeline.decide_qa_finding(finding, :skip) end)

      view |> element("#send-qa-findings-to-engineer") |> render_click()
      assert has_element?(view, "#qa-error", "nothing left for the engineer")
    end

    test "a change with something left to fix does not go to demo", %{
      conn: conn,
      task: task,
      decide_as_advised: decide_as_advised
    } do
      findings = decide_as_advised.()
      Enum.each(findings, fn finding -> {:ok, _skipped} = Pipeline.decide_qa_finding(finding, :skip) end)

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      assert has_element?(view, "#send-to-demo")

      [kept | _rest] = Pipeline.list_qa_findings(task)
      {:ok, _kept} = Pipeline.decide_qa_finding(kept, :fix)

      view |> element("#send-to-demo") |> render_click()
      assert has_element?(view, "#qa-error", "still outstanding")

      {:ok, _moved} = Pipeline.update_task(task, %{stage: :review})

      view |> element("#send-to-demo") |> render_click()
      assert has_element?(view, "#qa-error", "This task is at Review, not QA.")
    end

    test "a task with something running is not one to rule on", %{
      conn: conn,
      task: task,
      role: role,
      decide_as_advised: decide_as_advised
    } do
      [finding | _rest] = decide_as_advised.()

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      {:ok, _running} =
        Pipeline.create_run(%{
          task_id: task.id,
          role_id: role.id,
          status: :running,
          started_at: DateTime.utc_now()
        })

      view |> element("#decide-skip-#{finding.key}") |> render_click()

      assert has_element?(view, "#qa-error", "still running on this task")
    end

    test "a task that moved on under the reader refuses the ruling", %{
      conn: conn,
      task: task,
      decide_as_advised: decide_as_advised
    } do
      [finding | _rest] = decide_as_advised.()

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      {:ok, _moved} = Pipeline.update_task(task, %{stage: :review})

      view |> element("#decide-skip-#{finding.key}") |> render_click()

      assert has_element?(view, "#qa-error", "This task is at Review, not QA.")
    end

    # The verdict is read off disk, so nothing else would bring it up to date.
    test "a turn that lands underneath the reader is picked up", %{conn: conn, task: task, qa_run: run, raised: raised} do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      assert has_element?(view, "#qa-pending-title", "Nothing to fix")

      {:ok, _synced} = Pipeline.sync_qa_findings(task, raised)
      send(view.pid, {:os_process_finished, run, %{}})

      _settled = render(view)
      assert has_element?(view, "[data-qa='qa_finding_detail']", "The bill total renders as $1234.5")
    end
  end

  describe "the demo stage" do
    setup %{project: project, task: task} do
      {:ok, role} = Roles.get_role(project_id: project.id, stage: :demo)

      {:ok, task} = Pipeline.update_task(task, %{stage: :demo, worktree_path: create_temp_git_repo()})

      {:ok, demo_run} =
        Pipeline.create_run(%{
          task_id: task.id,
          role_id: role.id,
          status: :finished,
          stage_outcome: :done,
          conversation_id: "sess_demo_stage",
          started_at: DateTime.utc_now()
        })

      demo_dir = Path.join(task.scratch_path, "demo")
      File.mkdir_p!(demo_dir)

      recorded = fn ->
        File.write!(Path.join(demo_dir, "demo.webm"), "webm bytes")

        File.write!(Path.join(demo_dir, "TLV-1.json"), """
        {"title": "Bills can be filtered by vendor",
         "summary": "A vendor filter on the invoice index, narrowing the list as you type.",
         "not_shown": "The Plaid callback, which needs a real bank."}
        """)

        File.write!(Path.join(demo_dir, "captions.jsonl"), """
        {"at_ms": 0, "text": "Starting on the invoice index", "criterion": null}
        {"at_ms": 5200, "text": "Filtering to Sysco", "criterion": "Invoices can be filtered by vendor"}
        """)
      end

      %{task: task, role: role, demo_run: demo_run, demo_dir: demo_dir, recorded: recorded}
    end

    # A demo concludes nothing and moves nothing, so the panel is a player and an
    # index into it: the task stops here.
    test "plays the recording with its beats beside it", %{conn: conn, task: task, recorded: recorded} do
      recorded.()

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "[data-qa='demo_title']", "Bills can be filtered by vendor")
      assert has_element?(view, "[data-qa='demo_summary']", "narrowing the list as you type")
      assert has_element?(view, "#demo-video[src='/tasks/#{task.id}/demo/video']")
      assert has_element?(view, "[data-qa='demo_not_shown']", "The Plaid callback")

      assert has_element?(view, "#demo-beat-0", "Starting on the invoice index")
      assert has_element?(view, "#demo-beat-5200", "Filtering to Sysco")
      assert has_element?(view, "#demo-beat-5200 [data-qa='demo_beat_criterion']", "filtered by vendor")

      # A beat is an index into the video: the stamp is what a reader matches
      # against the player's own clock.
      assert has_element?(view, "#demo-beat-5200", "0:05")
    end

    # The whole point of recording the application is seeing the application, so
    # the caption has a bar of its own under the video rather than a box over it.
    test "the caption sits under the video, never over it", %{conn: conn, task: task, recorded: recorded} do
      recorded.()

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      caption = view |> element("#demo-caption") |> render()

      refute caption =~ "absolute"
      refute caption =~ "inset"

      # Empty until the player says which beat is up, and holding its height so
      # the layout does not move when one lands.
      assert caption =~ "min-h-"

      # The beats reach the player as data rather than as a <track>, which would
      # render its cues inside the video element.
      assert has_element?(view, "#demo-video-frame[phx-hook='DemoCaptions']")
      refute has_element?(view, "#demo-video track")
    end

    test "a demo the stage was entered without asks whether it is needed", %{
      conn: conn,
      task: task,
      demo_run: run,
      role: role
    } do
      Repo.delete!(run)

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "#task-tab-#{role.id}[aria-selected='true']")
      assert has_element?(view, "#demo-pending", "Nothing recorded yet.")

      view |> element("#skip-demo", "No demo needed") |> render_click()

      assert has_element?(view, "#demo-pending", "No demo is needed for this change.")
      refute has_element?(view, "#skip-demo")

      expect(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)
      view |> element("#record-demo", "Record a demo") |> render_click()

      assert %Task{demo_skipped_at: nil} = Repo.reload!(task)
    end

    test "a demo already recorded can be recorded again", %{conn: conn, task: task, recorded: recorded} do
      recorded.()

      expect(Tools, :start_os_process, fn spawned, ["-p", prompt | _rest] ->
        assert prompt =~ "fresh take"
        {:ok, %OsProcess{run: spawned}}
      end)

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      view |> element("#rerecord-demo", "Re-record") |> render_click()

      assert has_element?(view, "[data-qa='demo_running']")
    end

    test "a demo that cannot be recorded says why", %{conn: conn, task: task, demo_run: run} do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      {:ok, running} = Pipeline.update_run(run, %{status: :running})
      view |> with_target("#demo-stage") |> render_click("skip_demo", %{})
      assert has_element?(view, "#demo-error", "Something is still running on this task.")

      {:ok, _idle} = Pipeline.update_run(running, %{status: :finished})
      {:ok, _moved} = Pipeline.update_task(task, %{stage: :qa})
      view |> with_target("#demo-stage") |> render_click("record_demo", %{})
      assert has_element?(view, "#demo-error", "Could not do that: {:invalid_stage, :qa}")
    end

    test "a task nothing recorded has nothing to send", %{conn: conn, task: task} do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "#demo-pending", "Nothing recorded yet")
      assert has_element?(view, "[data-qa='demo_no_beats']")
    end

    test "a recording that could not be encoded says so rather than showing nothing", %{
      conn: conn,
      task: task,
      demo_run: run
    } do
      {:ok, _failed} =
        Pipeline.update_run(run, %{error: "The recording could not be encoded: ffmpeg is not installed."})

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "#demo-pending", "The last recording did not produce a video.")
      assert has_element?(view, "#task-error-card", "ffmpeg is not installed")
    end

    # A recording in flight has no video yet, so what is shown is the browser it
    # is being made from, with the beats landing as they are narrated.
    test "a demo still recording shows the browser and what has been said", %{
      conn: conn,
      task: task,
      demo_run: run,
      demo_dir: demo_dir
    } do
      {:ok, _running} = Pipeline.update_run(run, %{status: :running, stage_outcome: :in_progress})

      File.write!(
        Path.join(demo_dir, "captions.jsonl"),
        ~s({"at_ms": 1200, "text": "Opening the invoice index", "criterion": null}\n)
      )

      _logged =
        Pipeline.append_run_events(run.id, nil, [
          "[browser] goto http://localhost:4000/invoices",
          "[demo] say 0:01 Opening the invoice index",
          "[browser] do \"filter to Sysco\""
        ])

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "#demo-running", "Recording")
      assert has_element?(view, "#demo-screencast")
      assert has_element?(view, "[data-qa='demo_screencast_waiting']")
      assert has_element?(view, "[data-qa='demo_browser_url']", "localhost:4000/invoices")
      assert has_element?(view, "[data-qa='demo_doing']", "do")
      assert has_element?(view, "#demo-beats", "Narrated so far")
      assert has_element?(view, "#demo-beat-1200", "Opening the invoice index")

      refute has_element?(view, "#demo-video")
    end

    # A frame goes straight to the client: re-rendering the panel around a picture
    # arriving several times a second would diff everything else to move one image.
    test "frames from the browser reach the panel while it records", %{conn: conn, task: task, demo_run: run} do
      {:ok, _running} = Pipeline.update_run(run, %{status: :running, stage_outcome: :in_progress})

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      send(view.pid, {:browser_frame, task.id, "some-base64"})

      assert_push_event(view, "browser:frame", %{data: "some-base64"})
    end

    # The write-up is read off disk, so nothing else would bring it up to date.
    test "a recording that landed underneath the reader is picked up", %{
      conn: conn,
      task: task,
      demo_run: run,
      recorded: recorded
    } do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      assert has_element?(view, "#demo-pending")

      recorded.()
      send(view.pid, {:os_process_finished, run, %{}})

      _settled = render(view)
      assert has_element?(view, "[data-qa='demo_title']", "Bills can be filtered by vendor")
    end

    # The panel is the stage's, and the conversation beside it is the page's.
    test "the conversation sits beside the recording", %{conn: conn, task: task, recorded: recorded} do
      recorded.()

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "#task-conversation-column")
      assert has_element?(view, "[data-qa='conversation-tab']")
    end

    # The captions are on disk, so nothing tells the panel a beat landed. The run
    # says so in its own log as it happens, and that is already carried here.
    test "a beat narrated underneath the reader is picked up", %{conn: conn, task: task, demo_run: run, demo_dir: dir} do
      {:ok, _running} = Pipeline.update_run(run, %{status: :running, stage_outcome: :in_progress})

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      assert has_element?(view, "[data-qa='demo_no_beats']")

      File.write!(Path.join(dir, "captions.jsonl"), ~s({"at_ms": 800, "text": "Saving the bill"}\n))
      _logged = Pipeline.append_run_events(run.id, nil, ["[demo] say 0:00 Saving the bill"])

      _settled = render(view)
      assert has_element?(view, "#demo-beat-800", "Saving the bill")
    end
  end
end
