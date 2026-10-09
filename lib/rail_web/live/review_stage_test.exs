defmodule RailWeb.Live.ReviewStageTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.DemoBeat
  alias Rail.Pipeline.Schemas.Finding
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Schemas.BrowserSession
  alias Rail.Tools.Schemas.OsProcess
  alias Rail.Users

  setup %{conn: conn, project: project} do
    id = System.unique_integer([:positive])

    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "rst-1-#{id}",
        login: "dana-#{id}",
        name: "Dana",
        email: "dana-#{id}@rst.example"
      })

    {:ok, user} = Users.update_user(system_scope(), user, %{project_ids: [project.id]})
    {:ok, engineer} = Roles.get_role(project_id: project.id, stage: :engineer)
    {:ok, lead} = Roles.get_role(project_id: project.id, stage: :review_lead)
    task = learnings_task(project, "RST-1", :review)
    worktree = create_temp_git_repo()
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: worktree})
    head = worktree |> git!(["rev-parse", "HEAD"]) |> String.trim()

    {:ok, _engineer_run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: engineer.id,
        status: :finished,
        stage_outcome: :done,
        conversation_id: "sess_rst_engineer",
        started_at: DateTime.utc_now()
      })

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: lead.id,
        status: :finished,
        stage_outcome: :done,
        conversation_id: "sess_rst_lead",
        started_at: DateTime.utc_now()
      })

    code = %{
      kind: :code,
      raised_by: :code_reviewer,
      title: "A view-only member can send diff comments",
      problem: "The event never checks the member's role.",
      file: "lib/rail_web/live/engineer_stage.ex",
      line: 365,
      end_line: 381,
      fix: "Check the role inside the action.",
      why: "The hidden button is the only check.",
      rule: "Only a member who can edit the task can send its comments.",
      severity: :blocker,
      recommendation: :fix,
      places: [
        %{file: "lib/rail_web/live/engineer_stage.ex", line: 365, label: "handle_event(\"send_diff_comments\")"},
        %{file: "lib/rail/pipeline/actions/send_diff_comments.ex", line: 22, label: "send_diff_comments/2"}
      ],
      evidence: [%{name: "The handler", kind: :code, file: "lib/rail_web/live/engineer_stage.ex", line: 365}]
    }

    screen = %{
      kind: :screen,
      raised_by: :explorer,
      title: "Send stays enabled while a round is on its way",
      problem: "A second click sends the same comments twice.",
      screen: "Engineer tab, Diff toolbar",
      steps: ["Comment on 2 lines", "Click Send", "Click it again"],
      fix: "Disable Send until the server answers.",
      why: "Two runs for one round.",
      rule: "A round is sent once, however many times Send is pressed.",
      severity: :major,
      recommendation: :fix,
      places: [%{screen: "Engineer tab, Diff toolbar", label: "Send button"}],
      evidence: [%{name: "deliveries", kind: :log, text: "2 deliveries for one round"}]
    }

    %{conn: log_in_user(conn, user), user: user, task: task, run: run, head: head, code: code, screen: screen}
  end

  test "the rail shows Findings, Demo and Browser, each with its state as its title and the count still to rule", %{
    conn: conn,
    task: task,
    code: code,
    screen: screen
  } do
    {:ok, _code} = Pipeline.save_finding(task, Map.put(code, :key, "view-only-send"))
    {:ok, _screen} = Pipeline.save_finding(task, Map.put(screen, :key, "send-twice"))
    {:ok, _pass} = Pipeline.save_review(task)

    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    assert has_element?(view, "#review-items #review-item-findings[aria-current=true][title='Findings: 2 to rule']")
    assert has_element?(view, "#review-item-findings [data-qa=review_item_badge]", "2")
    assert has_element?(view, "#review-item-demo[title='Demo: None recorded']")
    assert has_element?(view, "#review-item-browser[title='Browser: No browsers open']")
    assert has_element?(view, "#review-item-findings .sr-only", "2 to rule")
    assert has_element?(view, "#task-tabs [aria-selected=true]", "2")
  end

  test "the list groups findings by round, newest first, with a Fix finding still failing carried into the round", %{
    conn: conn,
    task: task,
    code: code,
    screen: screen
  } do
    {:ok, carried} = Pipeline.save_finding(task, Map.put(screen, :key, "send-twice"))
    {:ok, _pass} = Pipeline.save_review(task)
    {:ok, _ruled} = Pipeline.decide_finding(system_scope(), carried, :fix)
    {:ok, _fixed} = Pipeline.save_finding(task, %{key: "send-twice", status: "fixed"})
    {:ok, _pass} = Pipeline.save_review(task)
    {:ok, _new} = Pipeline.save_finding(task, Map.put(code, :key, "view-only-send"))
    {:ok, %Finding{carried_round: 3}} = Pipeline.save_finding(task, %{key: "send-twice", status: "not_fixed"})
    {:ok, _pass} = Pipeline.save_review(task)

    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    assert ["Round 3", "Carried into round 3"] =
             view
             |> render()
             |> Floki.parse_document!()
             |> Floki.find("#review-finding-list [data-qa=review_finding_group] > p")
             |> Enum.map(&String.trim(Floki.text(&1)))

    assert has_element?(view, "#finding-send-twice [data-qa=review_finding_state]", "Fix · still failing on")
    assert has_element?(view, "#finding-view-only-send [data-qa=review_finding_state]", "Needs your call")
  end

  test "Start fix round is disabled until every finding is ruled, then starts the round; ruling moves on to the next", %{
    conn: conn,
    task: task,
    run: run,
    code: code,
    screen: screen
  } do
    {:ok, _code} = Pipeline.save_finding(task, Map.put(code, :key, "view-only-send"))
    {:ok, _screen} = Pipeline.save_finding(task, Map.put(screen, :key, "send-twice"))
    {:ok, _pass} = Pipeline.save_review(task)

    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    assert has_element?(view, "#start-fix-round[disabled][title='Rule on 2 more first']", "Start fix round 1")
    assert has_element?(view, "#review-finding-footer", "2 to rule")

    view |> element("#decide-fix-view-only-send") |> render_click()
    assert has_element?(view, "#finding-send-twice[aria-current=true]")
    assert %Finding{decision: :fix} = Repo.get_by!(Finding, task_id: task.id, key: "view-only-send")

    # The second click of a double click is held for a moment, so ruling the next one waits it out.
    Process.sleep(400)
    view |> element("#decide-skip-send-twice") |> render_click()
    assert has_element?(view, "#review-finding-footer", "1 to fix · 1 not fixing")
    refute has_element?(view, "#start-fix-round[disabled]")

    expect(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: %{spawned | status: :running}}} end)
    view |> element("#start-fix-round") |> render_click()

    assert %{stage_outcome: :in_progress} = Repo.reload!(run)
  end

  test "Start fix round reads Finish review when every finding is ruled Don't fix, and is gone once finished", %{
    conn: conn,
    task: task,
    code: code
  } do
    {:ok, finding} = Pipeline.save_finding(task, Map.put(code, :key, "view-only-send"))
    {:ok, _pass} = Pipeline.save_review(task)
    {:ok, _ruled} = Pipeline.decide_finding(system_scope(), finding, :skip)

    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
    assert has_element?(view, "#start-fix-round", "Finish review")

    view |> element("#start-fix-round") |> render_click()

    refute has_element?(view, "#start-fix-round")
    assert has_element?(view, "#review-status[data-phase=finished]", "Nothing left to rule")
    assert has_element?(view, "#review-item-findings [data-qa=review_item_done]")
    assert has_element?(view, "#task-status-chip", "Ready to merge")
  end

  test "a finding reads whole: Problem, Where, Fix, Why, its evidence, the rule with every place, its commits and history",
       %{conn: conn, user: user, task: task, head: head, code: code, screen: screen} do
    {:ok, finding} = Pipeline.save_finding(task, Map.merge(code, %{key: "view-only-send", note: "From the diff."}))
    {:ok, _pass} = Pipeline.save_review(task)
    {:ok, _ruled} = Pipeline.decide_finding(user_scope(user: user), finding, :fix)
    {:ok, _screen} = Pipeline.save_finding(task, Map.put(screen, :key, "send-twice"))
    short = String.slice(head, 0, 7)

    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
    view |> element("#finding-view-only-send") |> render_click()

    assert has_element?(view, "#review-finding-detail [data-qa=finding_round]", "Round 1")
    assert has_element?(view, "[data-qa=finding_problem]", "The event never checks the member's role.")
    assert has_element?(view, "[data-qa=finding_where]", "lib/rail_web/live/engineer_stage.ex:365-381")
    assert has_element?(view, "[data-qa=finding_fix]", "Check the role inside the action.")
    assert has_element?(view, "[data-qa=finding_why]", "Why fix")
    assert has_element?(view, "[data-qa=finding_recommendation]", "Code reviewer recommends Fix")
    assert has_element?(view, "#finding-rule", "Only a member who can edit the task can send its comments.")
    assert has_element?(view, "#finding-rule", "Applies in 2 places")
    assert has_element?(view, "#finding-rule [data-qa=finding_place]", "send_diff_comments/2")
    assert has_element?(view, "[data-qa=finding_raised_in]", short)
    assert has_element?(view, "[data-qa=finding_fixed_in]", "not yet")
    assert has_element?(view, "[data-qa=finding_note]", "Raised on #{short}, from code reviewer: From the diff.")
    assert has_element?(view, "[data-qa=finding_note]", "You ruled Fix")

    view |> element("#finding-send-twice") |> render_click()
    assert has_element?(view, "[data-qa=finding_where] ol li", "Click it again")
    assert has_element?(view, "#finding-evidence [data-qa=finding_evidence_taken]", "Taken on #{short}")
    assert has_element?(view, "#finding-evidence [data-qa=finding_evidence_text]", "2 deliveries for one round")
    assert has_element?(view, "[data-qa=finding_recommendation]", "QA explorer recommends Fix")
  end

  test "a fix round's note says what it covered, left and tested, and Fixed in names the commit", %{
    conn: conn,
    task: task,
    run: run,
    code: code
  } do
    {:ok, finding} = Pipeline.save_finding(task, Map.put(code, :key, "view-only-send"))
    {:ok, _pass} = Pipeline.save_review(task)
    {:ok, _ruled} = Pipeline.decide_finding(system_scope(), finding, :fix)

    {:ok, _fixed} =
      Finding
      |> Repo.get!(finding.id)
      |> Finding.note_changeset(%{
        status: :fixed,
        fixed_in: "abc1234def",
        note: %{
          round: 1,
          kind: :fix,
          at: DateTime.utc_now(),
          commit: "abc1234def",
          covered: ["lib/rail_web/live/engineer_stage.ex:365"],
          left: ["lib/rail/pipeline/actions/send_diff_comments.ex:22: already checked"],
          test: "test/a_test.exs: refuses a view-only member"
        }
      })
      |> Repo.update()

    {:ok, _pass} = Pipeline.update_run(run, %{status: :finished})
    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    assert has_element?(view, "#finding-view-only-send [data-qa=review_finding_state]", "Fixed in abc1234")
    assert has_element?(view, "[data-qa=finding_fixed_in]", "abc1234")

    assert has_element?(
             view,
             "[data-qa=finding_note]",
             "Fixed in abc1234; covers lib/rail_web/live/engineer_stage.ex:365; leaves " <>
               "lib/rail/pipeline/actions/send_diff_comments.ex:22: already checked; test that failed first: " <>
               "test/a_test.exs: refuses a view-only member"
           )

    assert has_element?(view, "[data-qa=finding_note] + span, [data-qa=finding_note]", "Fix round 1")
  end

  test "while a round runs nothing asks for a call, and the status names the agents at work", %{
    conn: conn,
    task: task,
    run: run,
    code: code
  } do
    {:ok, _finding} = Pipeline.save_finding(task, Map.put(code, :key, "view-only-send"))
    {:ok, run} = Pipeline.update_run(run, %{status: :running, stage_outcome: :in_progress})

    {:ok, agent} =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: task.id,
        stream_path: "/tmp/rst/#{run.id}.ndjson",
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert()

    Pipeline.append_run_events(run.id, agent.id, [
      "Starting round 1.",
      "[subagent tu_1] code-reviewer · Read the branch against the plan",
      "[subagent tu_2] explorer · explorer-1: Checks 1 and 2"
    ])

    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    assert has_element?(view, "#review-status[data-phase=round]", "Round 1 · Code reviewer and 1 QA explorer working")
    assert has_element?(view, "[data-qa=review_status_agent]", "QA explorer 1")
    assert has_element?(view, "[data-qa=review_status_agent]", "Checks 1 and 2")
    assert has_element?(view, "#review-item-findings [data-qa=review_item_running]")
    assert has_element?(view, "#start-fix-round[disabled][title='Round 1 is still running']")
    assert has_element?(view, "#review-finding-footer", "1 so far · rule once round 1 finishes")
    refute has_element?(view, "#decide-fix-view-only-send")
    refute has_element?(view, "[data-qa=review_finding_state]", "Needs your call")
  end

  test "CI on the fix commit shows the end of its log, and CI failed three times says so", %{
    conn: conn,
    project: project,
    task: task,
    run: run,
    head: head
  } do
    {:ok, _project} = Projects.update_project(system_scope(), project, %{ci_command: "mise run ci"})
    {:ok, _pass} = Pipeline.save_review(task)
    {:ok, run} = Pipeline.update_run(run, %{status: :running})
    log = Path.join(System.tmp_dir!(), "rst_ci_#{run.id}.log")
    File.write!(log, "==> rail\nCompiling 14 files (.ex)\nRunning ExUnit\n\n")

    {:ok, ci} =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: task.id,
        kind: :ci,
        command: "mise run ci",
        stream_path: log,
        status: :running,
        head_sha: head,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert()

    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
    short = String.slice(head, 0, 7)

    assert has_element?(view, "#review-status[data-phase=ci]", "CI running on #{short} · Fix round 1")
    assert has_element?(view, "[data-qa=review_status_log]", "Running ExUnit")
    assert has_element?(view, "#review-item-findings[title='Findings: CI running on #{short}']")
    refute has_element?(view, "#start-fix-round")

    {:ok, _failed} = ci |> OsProcess.changeset(%{status: :finished, exit_code: 1}) |> Repo.update()
    {:ok, _stopped} = Pipeline.update_run(run, %{status: :finished, ci_failure_streak: 3, error: "CI failed 3 times"})
    send(view.pid, {:pipeline_changed, task.id})

    assert has_element?(view, "#review-status[data-phase=ci_failed]", "CI failed 3 times on fix round 1")
    assert has_element?(view, "#review-item-findings [data-qa=review_item_failed]")
  end

  test "a fix round in progress says the engineer is fixing, and the footer counts what is being fixed", %{
    conn: conn,
    task: task,
    run: run,
    code: code
  } do
    {:ok, finding} = Pipeline.save_finding(task, Map.put(code, :key, "view-only-send"))
    {:ok, _pass} = Pipeline.save_review(task)
    {:ok, _ruled} = Pipeline.decide_finding(system_scope(), finding, :fix)
    {:ok, _working} = Pipeline.update_run(run, %{status: :running})

    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    assert has_element?(view, "#review-status[data-phase=fixing]", "Fix round 1 · Engineer fixing 1 finding")
    assert has_element?(view, "#review-finding-footer", "1 fixing")
    refute has_element?(view, "#start-fix-round")
  end

  test "the next round's status names the commit it re-reviews", %{conn: conn, task: task, run: run, head: head} do
    {:ok, _pass} = Pipeline.save_review(task)
    {:ok, _working} = Pipeline.update_run(run, %{status: :running})

    stub(Pipeline, :get_ci_status, fn _run ->
      %{state: :passed, os_process: %OsProcess{head_sha: head}, failures: 0, tail: []}
    end)

    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    assert has_element?(view, "#review-status[data-phase=round]", "Round 2 · Re-review of #{String.slice(head, 0, 7)}")
  end

  test "the Demo item plays the recording with its walkthrough, and says what it was recorded on", %{
    conn: conn,
    task: task
  } do
    demo_dir = Path.join(task.scratch_path, "demo")
    File.mkdir_p!(demo_dir)
    File.write!(Path.join(demo_dir, "demo.webm"), "webm")

    File.write!(
      Path.join(demo_dir, "RST-1.json"),
      ~s({"title": "Filters", "summary": "It filters.", "commit": "7b19e4cabc"})
    )

    File.write!(
      Path.join(demo_dir, "captions.jsonl"),
      ~s({"at_ms": 0, "video_ms": 0, "text": "The Engineer tab", "criterion": "AC 1"}\n)
    )

    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
    assert has_element?(view, "#review-item-demo[title='Demo: Recorded on 7b19e4c']")

    view |> element("#review-item-demo") |> render_click()

    assert has_element?(view, "#review-demo [data-qa=review_demo_header]", "Recorded on 7b19e4c")
    assert has_element?(view, "#demo-player [data-qa=demo_title]", "Filters")
    assert has_element?(view, "#demo-video")
    assert has_element?(view, "#demo-beats [data-qa=demo_beat]", "The Engineer tab")
    assert has_element?(view, "[data-qa=demo_beat_criterion]", "AC 1")
  end

  test "with nothing recorded the Demo item says so", %{conn: conn, task: task} do
    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
    view |> element("#review-item-demo") |> render_click()

    assert has_element?(view, "#review-demo [data-qa=review_demo_header]", "None recorded")
    assert has_element?(view, "[data-qa=review_demo_none]", "No demo was recorded.")
  end

  test "the Browser item offers each tab by QA explorer N or Demo recorder with its account, and the demo's beats", %{
    conn: conn,
    task: task,
    run: run
  } do
    now = DateTime.utc_now()

    for {name, account, at} <- [
          {"explorer-1", "explorer-1@rail.test", now},
          {"demo", "demo@rail.test", DateTime.shift(now, second: 1)}
        ] do
      Repo.insert!(%BrowserSession{task_id: task.id, name: name, account: account, status: :running, started_at: at})
    end

    Repo.insert!(%BrowserSession{task_id: task.id, name: "explorer-2", status: :finished, started_at: now})
    {:ok, _working} = Pipeline.update_run(run, %{status: :running})
    recorder = spawn(fn -> Process.sleep(:infinity) end)
    stub(Tools, :get_browser_recording, fn _task -> recorder end)
    stub(Tools, :get_browser_session, fn _task, "explorer-1" -> self() end)
    stub(Tools, :get_browser_url, fn _task, _name -> "localhost:4012/tasks" end)
    stub(Pipeline, :list_demo_beats, fn _task -> [%DemoBeat{at_ms: 0, text: "One"}, %DemoBeat{at_ms: 1, text: "Two"}] end)

    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    assert has_element?(view, "#review-item-browser[title='Browser: 1 recording']")
    assert has_element?(view, "#review-item-browser [data-qa=review_item_recording]")
    assert has_element?(view, "#review-item-demo[title='Demo: Recording · 2 beats said so far']")

    view |> element("#review-item-browser") |> render_click()

    assert has_element?(view, "[data-qa=review_browser_summary]", "1 recording, 1 driving")
    assert has_element?(view, "#review-browser-explorer-1[aria-pressed=true]", "QA explorer 1")
    assert has_element?(view, "#review-browser-explorer-1", "explorer-1@rail.test")
    assert has_element?(view, "#review-browser-demo", "Demo recorder")
    refute has_element?(view, "#review-browser-explorer-2")
    assert has_element?(view, "[data-qa=review_browser_url]", "localhost:4012/tasks")
    assert has_element?(view, "[data-qa=review_browser_line]", "Driving · signed in as explorer-1@rail.test")

    view |> element("#review-browser-demo") |> render_click()

    assert has_element?(view, "#review-browser-demo[aria-pressed=true]")

    assert has_element?(
             view,
             "[data-qa=review_browser_line]",
             "Recording · 2 beats said so far · signed in as demo@rail.test"
           )

    assert has_element?(view, "#review-screencast-demo")
  end

  test "with no browser open the Browser item says so", %{conn: conn, task: task} do
    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
    view |> element("#review-item-browser") |> render_click()

    assert has_element?(view, "[data-qa=review_browser_none]")
  end

  test "a code finding marks its whole range in its hunk, and no line outside it or replaced", %{
    conn: conn,
    task: %{worktree_path: worktree} = task,
    code: code
  } do
    File.write!(Path.join(worktree, "example.ex"), Enum.map_join(1..8, "", &"line #{&1}\n"))
    git!(worktree, ["add", "."])
    git!(worktree, ["commit", "-m", "before"])
    git!(worktree, ["update-ref", "refs/remotes/origin/main", "HEAD"])

    File.write!(
      Path.join(worktree, "example.ex"),
      Enum.map_join(1..8, "", &if(&1 in 3..5, do: "changed #{&1}\n", else: "line #{&1}\n"))
    )

    git!(worktree, ["commit", "-am", "the change"])

    {:ok, _finding} =
      Pipeline.save_finding(task, Map.put(%{code | file: "example.ex", line: 3, end_line: 5}, :key, "range"))

    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    assert ["+ changed3", "+ changed4", "+ changed5"] =
             view
             |> render()
             |> Floki.parse_document!()
             |> Floki.find("[data-qa=finding_diff] [data-focus]")
             |> Enum.map(&(&1 |> Floki.text() |> String.split() |> Enum.take(-2) |> Enum.join(" ")))
  end

  # The log's opening was read into the finding when attached, so the tab shows it with no file opened.
  test "each evidence tab shows its piece: a log's text from the finding, a screenshot as the picture", %{
    conn: conn,
    task: task,
    screen: screen
  } do
    qa = Path.join(task.scratch_path, "qa")
    File.mkdir_p!(Path.join(qa, "shots"))
    File.write!(Path.join(qa, "shots/send-twice-1.jpg"), "jpeg bytes")
    File.write!(Path.join(qa, "server.log"), "two deliveries\n")
    File.write!(Path.join(qa, "invoice.pdf"), "%PDF-1.7")
    File.write!(Path.join(qa, "export.bin"), <<0, 159, 146, 150>>)

    evidence = [
      %{name: "Send twice", kind: :screenshot, path: "shots/send-twice-1.jpg", browser: "explorer-1"},
      %{name: "Server log", kind: :log, path: "server.log"},
      %{name: "The invoice", kind: :log, path: "invoice.pdf"},
      %{name: "The export", kind: :log, path: "export.bin"}
    ]

    {:ok, _finding} = Pipeline.save_finding(task, Map.merge(screen, %{key: "send-twice", evidence: evidence}))

    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    assert has_element?(
             view,
             "#finding-evidence img[alt='Send twice'][src='/tasks/#{task.id}/findings/send-twice/evidence/0']"
           )

    assert has_element?(view, "#finding-evidence-2 .pi-file-pdf")
    assert has_element?(view, "#finding-evidence-3 .pi-file")

    File.rm_rf!(qa)
    view |> element("#finding-evidence-1") |> render_click()
    assert has_element?(view, "#finding-evidence-1[aria-selected=true]")
    assert has_element?(view, "[data-qa=finding_evidence_text]", "two deliveries")
  end

  test "the Demo item counts a single beat said, and a demo saved without its commit reads Recorded", %{
    conn: conn,
    task: task
  } do
    recorder = spawn(fn -> Process.sleep(:infinity) end)
    stub(Tools, :get_browser_recording, fn _task -> recorder end)
    stub(Pipeline, :list_demo_beats, fn _task -> [%DemoBeat{at_ms: 0, text: "One"}] end)

    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
    assert has_element?(view, "#review-item-demo[title='Demo: Recording · 1 beat said so far']")

    demo_dir = Path.join(task.scratch_path, "demo")
    File.mkdir_p!(demo_dir)
    File.write!(Path.join(demo_dir, "demo.webm"), "webm")
    File.write!(Path.join(demo_dir, "RST-1.json"), ~s({"title": "Filters", "summary": "It filters."}))
    stub(Tools, :get_browser_recording, fn _task -> nil end)

    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
    assert has_element?(view, "#review-item-demo[title='Demo: Recorded']")
  end

  test "a task that has moved on from Review offers no fix round", %{conn: conn, task: task, run: run, code: code} do
    {:ok, _finding} = Pipeline.save_finding(task, Map.put(code, :key, "view-only-send"))
    {:ok, _pass} = Pipeline.save_review(task)
    {:ok, _merged} = Pipeline.update_task(task, %{stage: :merged})

    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}?tab=#{run.role_id}")

    assert has_element?(view, "#finding-view-only-send")
    refute has_element?(view, "#start-fix-round")
    refute has_element?(view, "#decide-fix-view-only-send")
  end

  test "a fix round that is refused says why", %{conn: conn, task: task, code: code} do
    {:ok, finding} = Pipeline.save_finding(task, Map.put(code, :key, "view-only-send"))
    {:ok, _pass} = Pipeline.save_review(task)
    {:ok, _ruled} = Pipeline.decide_finding(system_scope(), finding, :fix)
    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    for {reason, said} <- [
          nothing_to_start: "There is nothing left to start: the review is finished.",
          dispatch_disabled: "Dispatch is off, so the Review lead was not resumed."
        ] do
      expect(Pipeline, :start_fix_round, fn _run -> {:error, reason} end)
      view |> element("#start-fix-round") |> render_click()

      assert has_element?(view, "#review-error", said)
    end
  end
end
