defmodule RailWeb.TaskLiveTest do
  use RailWeb.ConnCase, async: true

  import Mimic
  import Phoenix.LiveViewTest

  alias Rail.Git
  alias Rail.GitHub.Client
  alias Rail.Issues
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

  setup %{conn: conn} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_task_live",
        login: "task_live_user",
        email: "task_live_user@example.com",
        admin: true
      })

    scope = Scope.for_user(user)

    {:ok, backend} = Tools.create_backend(system_scope(), %{name: :claude, executable_path: "/usr/bin/true"})

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "lin_team_id"}]}}})
    end)

    {:ok, project} =
      Projects.create_project(scope, %{
        name: "Task Live Project",
        github_repo: "org/task-live",
        github_installation_id: 46_001,
        linear_workspace: %{
          name: "Task Live Workspace",
          external_id: "lin_ws_task_live",
          token: "lin_api_token_task_live",
          webhook_secret: "whsec_task_live"
        },
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

  test "approving while the run is still working says so", %{conn: conn, task: task, run: run} do
    {:ok, _working} = Pipeline.update_run(run, %{status: :running, stage_outcome: :in_progress})
    File.write!(Path.join([task.scratch_path, "tickets", "TLV-1.md"]), "# A ticket\n\nBody.")

    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

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
    project: project,
    backend: backend
  } do
    {:ok, engineer} =
      Roles.create_role(system_scope(), project, %{
        backend_id: backend.id,
        stage: :engineer,
        name: "engineer role",
        model: "claude-3-7-sonnet",
        system_prompt: "You are the engineer agent."
      })

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
      project: project,
      backend: backend
    } do
      File.write!(Path.join([task.scratch_path, "tickets", "TLV-1.md"]), "The ticket as approved.")

      {:ok, architect} =
        Roles.create_role(system_scope(), project, %{
          backend_id: backend.id,
          stage: :architect,
          name: "architect role",
          model: "claude-3-7-sonnet",
          system_prompt: "You are the architect agent."
        })

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
      project: project,
      backend: backend
    } do
      {:ok, qa} =
        Roles.create_role(system_scope(), project, %{
          backend_id: backend.id,
          stage: :qa,
          name: "qa role",
          model: "claude-3-7-sonnet",
          system_prompt: "You are the QA agent."
        })

      {:ok, _testing} =
        Pipeline.create_run(%{
          task_id: task.id,
          role_id: qa.id,
          status: :running,
          started_at: DateTime.utc_now()
        })

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      view |> element("#task-tab-#{qa.id}") |> render_click()

      assert has_element?(view, "[data-qa='role_no_work']")
      assert has_element?(view, "[data-qa='conversation-tab']")
    end

    test "a role that has not run has no tab yet", %{conn: conn, task: task, project: project, backend: backend} do
      {:ok, architect} =
        Roles.create_role(system_scope(), project, %{
          backend_id: backend.id,
          stage: :architect,
          name: "architect role",
          model: "claude-3-7-sonnet",
          system_prompt: "You are the architect agent."
        })

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
      project: project,
      backend: backend
    } do
      {:ok, architect} =
        Roles.create_role(system_scope(), project, %{
          backend_id: backend.id,
          stage: :architect,
          name: "architect role",
          model: "claude-3-7-sonnet",
          system_prompt: "You are the architect agent."
        })

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
    setup %{backend: backend, project: project, task: task} do
      {:ok, design_role} =
        Roles.create_role(system_scope(), project, %{
          backend_id: backend.id,
          stage: :design,
          name: "design role",
          model: "claude-3-7-sonnet",
          system_prompt: "You are the design agent."
        })

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
      # action on the task, the way approving a ticket does.
      assert has_element?(view, "#task-header #approve-design")
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
  end

  describe "the architect stage" do
    setup %{backend: backend, project: project, task: task} do
      roles =
        Map.new([:architect, :engineer], fn stage ->
          {:ok, role} =
            Roles.create_role(system_scope(), project, %{
              backend_id: backend.id,
              stage: stage,
              name: "#{stage} role",
              model: "claude-3-7-sonnet",
              system_prompt: "You are the #{stage} agent."
            })

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
  end

  describe "the engineer stage" do
    setup %{backend: backend, project: project, task: task} do
      {:ok, role} =
        Roles.create_role(system_scope(), project, %{
          backend_id: backend.id,
          stage: :engineer,
          name: "engineer role",
          model: "claude-3-7-sonnet",
          system_prompt: "You are the engineer agent."
        })

      # The pane's buttons are about what is outstanding, so the worktree starts
      # where a finished round leaves it: committed and pushed.
      remote = create_temp_git_repo(prefix: "rail_git_remote", initial_commit: false)
      git!(remote, ["config", "receive.denyCurrentBranch", "ignore"])

      repo = create_temp_git_repo()
      git!(repo, ["remote", "add", "origin", remote])
      git!(repo, ["checkout", "-b", "feature"])
      File.write!(Path.join(repo, "shipped.ex"), "committed\n")
      git!(repo, ["add", "."])
      git!(repo, ["commit", "-m", "the engineer's work"])
      git!(repo, ["push", "--set-upstream", "origin", "feature"])

      {:ok, task} = Pipeline.update_task(task, %{stage: :engineer, worktree_path: repo})

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
      render_async(view)

      assert has_element?(view, "#engineer-error", "remote rejected")
      assert has_element?(view, "#commit-work", "Push")

      stub(Git, :push_branch, fn _scope, %Task{worktree_path: path} ->
        git!(path, ["push", "--set-upstream", "origin", "HEAD"])
        :ok
      end)

      view |> element("#commit-work") |> render_click()
      render_async(view)

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

      send(pusher, :release)
      render_async(view)

      refute has_element?(view, "#commit-work")
      refute has_element?(view, "#send-to-review[disabled]")
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
      render_async(view)

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

    test "selecting a file in the tree marks it", %{conn: conn, task: task} do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      _clicked = view |> element("[data-qa='diff-file-row']") |> render_click()

      assert has_element?(view, "[data-qa='diff-file-row'][aria-current='true']", "shipped.ex")
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
      render_async(view)

      assert has_element?(view, "#engineer-error", "nothing left to commit")
    end

    test "a commit git refused in its own words repeats them", %{conn: conn, task: task, repo: repo} do
      File.write!(Path.join(repo, "wip.ex"), "uncommitted\n")
      stub(Git, :commit_worktree, fn _scope, _task, _message -> {:error, "index.lock exists"} end)

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      view |> element("#commit-work") |> render_click()
      render_async(view)

      assert has_element?(view, "#engineer-error", "index.lock exists")
    end

    test "a push GitHub would not authorize says what came back", %{conn: conn, task: task, repo: repo} do
      File.write!(Path.join(repo, "wip.ex"), "uncommitted\n")

      Req.Test.stub(Client, fn req_conn ->
        req_conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "Not Found"})
      end)

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      view |> element("#commit-work") |> render_click()
      render_async(view)

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
    setup %{backend: backend, project: project, task: task, run: run} do
      {:ok, other_role} =
        Roles.create_role(system_scope(), project, %{
          backend_id: backend.id,
          stage: :design,
          name: "design role",
          model: "claude-3-7-sonnet",
          system_prompt: "You are the design agent."
        })

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

      assert has_element?(view, "#chat-input[value='']")
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

      assert has_element?(view, "#chat-input[value='Please add a test']")
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
    setup %{backend: backend, project: project, task: task} do
      {:ok, role} =
        Roles.create_role(system_scope(), project, %{
          backend_id: backend.id,
          stage: :review,
          name: "review role",
          model: "claude-3-7-sonnet",
          system_prompt: "You are the review agent."
        })

      {:ok, engineer_role} =
        Roles.create_role(system_scope(), project, %{
          backend_id: backend.id,
          stage: :engineer,
          name: "engineer role",
          model: "claude-3-7-sonnet",
          system_prompt: "You are the engineer agent."
        })

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

      %{task: task, role: role, review_run: review_run, raised: raised}
    end

    test "lists every finding with its severity and what the reviewer advised", %{
      conn: conn,
      task: task,
      raised: raised
    } do
      {:ok, _synced} = Pipeline.sync_review_findings(task, raised)

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "#review-findings")
      assert has_element?(view, "[data-qa='review_group_to_fix']", "Nil is not handled")
      assert has_element?(view, "[data-qa='finding_location']", "lib/rail/example.ex:12")
      assert has_element?(view, "[data-qa='finding_recommendation']", "recommends fixing this")
      assert has_element?(view, "[data-qa='review_group_dismissed']", "Poor variable name")
      assert has_element?(view, "[data-qa='finding_recommendation']", "recommends leaving this")
    end

    test "a finding the reviewer checked again shows as fixed", %{conn: conn, task: task, raised: raised} do
      {:ok, _synced} = Pipeline.sync_review_findings(task, List.update_at(raised, 0, &%{&1 | status: :fixed}))

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "[data-qa='review_group_fixed']", "Nil is not handled")
    end

    test "the human overrules a recommendation and the finding moves", %{conn: conn, task: task, raised: raised} do
      {:ok, [finding | _rest]} = Pipeline.sync_review_findings(task, raised)

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      assert has_element?(view, "[data-qa='review_group_to_fix']", "Nil is not handled")

      view |> element("#toggle-decision-#{finding.id}") |> render_click()

      assert has_element?(view, "[data-qa='review_group_dismissed']", "Nil is not handled")
      refute has_element?(view, "[data-qa='review_group_to_fix']")
      assert has_element?(view, "[data-qa='finding_recommendation']", "You dismissed it.")
    end

    test "outstanding findings go back to the engineer", %{conn: conn, task: task, raised: raised} do
      {:ok, _synced} = Pipeline.sync_review_findings(task, raised)

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

    test "dismissing the last outstanding finding is what opens QA", %{conn: conn, task: task, raised: raised} do
      {:ok, [finding | _rest]} = Pipeline.sync_review_findings(task, raised)

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      refute has_element?(view, "#send-to-qa")

      view |> element("#toggle-decision-#{finding.id}") |> render_click()

      assert has_element?(view, "#send-to-qa")
      refute has_element?(view, "#send-findings-to-engineer")
    end

    test "a reviewer still reading offers neither button", %{conn: conn, task: task, review_run: run, raised: raised} do
      {:ok, _synced} = Pipeline.sync_review_findings(task, raised)
      {:ok, _running} = Pipeline.update_run(run, %{status: :running, stage_outcome: :in_progress})

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      refute has_element?(view, "#send-findings-to-engineer")
      refute has_element?(view, "#send-to-qa")
      refute has_element?(view, "[data-qa='toggle_decision']")
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

    test "every severity is read at a glance", %{conn: conn, task: task} do
      {:ok, _synced} =
        Pipeline.sync_review_findings(task, [
          %{key: "a-blocker", title: "A blocker", severity: :blocker, recommendation: :fix, status: :open},
          %{key: "a-major", title: "A major", severity: :major, recommendation: :fix, status: :open},
          %{key: "a-minor", title: "A minor", severity: :minor, recommendation: :fix, status: :open},
          %{key: "a-nit", title: "A nit", severity: :nit, recommendation: :fix, status: :open}
        ])

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      for label <- ["Blocker", "Major", "Minor", "Nit"] do
        assert has_element?(view, "[data-qa='review_finding']", label)
      end
    end

    test "a finding the engineer did not fix is grouped on its own", %{conn: conn, task: task} do
      {:ok, _synced} =
        Pipeline.sync_review_findings(task, [
          %{
            key: "unhandled-nil",
            title: "Nil is not handled",
            file: "lib/rail/example.ex",
            severity: :major,
            recommendation: :fix,
            status: :not_fixed
          }
        ])

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "[data-qa='review_group_not_fixed']", "Nil is not handled")
      assert has_element?(view, "[data-qa='finding_location']", "lib/rail/example.ex")
      assert has_element?(view, "#send-findings-to-engineer")
    end

    test "the human takes on a finding the reviewer would have left", %{conn: conn, task: task, raised: raised} do
      {:ok, [_blocker, nit]} = Pipeline.sync_review_findings(task, raised)

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      view |> element("#toggle-decision-#{nit.id}") |> render_click()

      assert has_element?(view, "[data-qa='review_group_to_fix']", "Poor variable name")
      assert has_element?(view, "[data-qa='finding_recommendation']", "You chose to fix it.")
      assert has_element?(view, "#send-findings-to-engineer", "Send 2 back to engineer")
    end

    test "a finding raised underneath the page stops it going to QA", %{conn: conn, task: task, raised: raised} do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      assert has_element?(view, "#send-to-qa")

      {:ok, _synced} = Pipeline.sync_review_findings(task, raised)
      view |> element("#send-to-qa") |> render_click()

      assert has_element?(view, "#review-error", "still outstanding")
      assert %Task{stage: :review} = Repo.reload!(task)
    end

    test "findings dismissed underneath the page leave nothing to send back", %{
      conn: conn,
      task: task,
      raised: raised
    } do
      {:ok, findings} = Pipeline.sync_review_findings(task, raised)

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
      {:ok, [finding | _rest]} = Pipeline.sync_review_findings(task, raised)

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      {:ok, _running} = Pipeline.update_run(run, %{status: :running})
      view |> element("#toggle-decision-#{finding.id}") |> render_click()

      assert has_element?(view, "#review-error", "still running on this task")
    end

    test "a task moved on underneath the page says where it went", %{conn: conn, task: task} do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      {:ok, _moved} = Pipeline.update_task(task, %{stage: :qa})
      view |> element("#send-to-qa") |> render_click()

      assert has_element?(view, "#review-error", "This task is at QA, not review.")
    end

    test "a project with no engineer says so rather than losing the findings", %{
      conn: conn,
      task: task,
      project: project,
      raised: raised
    } do
      {:ok, _synced} = Pipeline.sync_review_findings(task, raised)

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      {:ok, engineer_role} = Roles.get_role(project_id: project.id, stage: :engineer)
      {:ok, _deleted} = Roles.delete_role(system_scope(), engineer_role)

      view |> element("#send-findings-to-engineer") |> render_click()

      assert has_element?(view, "#review-error", "no engineer to send the findings to")
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
      assert has_element?(view, "[data-qa='review_group_to_fix']", "Nil is not handled")
    end
  end
end
