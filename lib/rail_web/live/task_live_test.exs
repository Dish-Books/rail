defmodule RailWeb.TaskLiveTest do
  use RailWeb.ConnCase, async: true

  import Mimic
  import Phoenix.LiveViewTest

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

  test "the page hosts the conversation for the runs the task has", %{conn: conn, task: task, role: role} do
    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    assert has_element?(view, "[data-qa='conversation-tab']")
    assert has_element?(view, "#role-chip-#{role.id}")
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

      assert has_element?(view, "#role-chip-#{other_role.id}")

      view |> element("#role-chip-#{other_role.id}") |> render_click()
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

    test "a role with no run is not selected", %{conn: conn, task: task, role: role} do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      view |> element("#role-chip-#{role.id}") |> render_click(%{"role_id" => "rol_missing"})

      assert has_element?(view, "#metadata-run-conversation-id", "sess_product")
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
end
