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

  test "the rail shows Findings, Diff, Screens, Demo and Browser, each with its state as its title", %{
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
    assert has_element?(view, "#review-item-diff[title='Diff: No commits yet']")
    assert has_element?(view, "#review-item-screens[title='Screens: No screens yet']")
    assert has_element?(view, "#review-item-demo[title='Demo: None recorded']")
    assert has_element?(view, "#review-item-browser[title='Browser: No browsers open']")

    assert ["findings", "diff", "screens", "demo", "browser"] =
             view
             |> render()
             |> Floki.parse_document!()
             |> Floki.find("#review-items button")
             |> Enum.flat_map(&Floki.attribute(&1, "phx-value-item"))

    assert has_element?(view, "#review-item-findings .sr-only", "2 to rule")
    assert has_element?(view, "#task-tabs [aria-selected=true]", "2")
  end

  test "the list groups findings by round, newest first, with a Fix finding still failing carried into the round", %{
    conn: conn,
    task: %{worktree_path: worktree} = task,
    code: code,
    screen: screen
  } do
    {:ok, carried} = Pipeline.save_finding(task, Map.put(screen, :key, "send-twice"))
    {:ok, _pass} = Pipeline.save_review(task)
    {:ok, _ruled} = Pipeline.decide_finding(system_scope(), carried, :fix)
    # A round is a read of a new HEAD, so each fix round commits before its pass.
    git!(worktree, ["commit", "--allow-empty", "-m", "fix round 1"])

    {:ok, _fixed} =
      Pipeline.save_finding(task, %{
        key: "send-twice",
        status: "fixed",
        covered: [1],
        test: %{file: "test/send_test.exs", name: "sends once"}
      })

    {:ok, _pass} = Pipeline.save_review(task)
    git!(worktree, ["commit", "--allow-empty", "-m", "fix round 2"])
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

  test "Send is disabled until every finding is ruled, then starts the round; ruling moves on to the next", %{
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

    assert has_element?(view, "#finish-review[disabled]")
    assert has_element?(view, "#review-send-tray-hint", "Rule on 2 more findings before you send.")
    assert has_element?(view, "#review-finding-footer", "2 to rule")
    refute has_element?(view, "#review-finding-footer button")

    view |> element("#decide-fix-view-only-send") |> render_click()
    assert has_element?(view, "#finding-send-twice[aria-current=true]")
    assert %Finding{decision: :fix} = Repo.get_by!(Finding, task_id: task.id, key: "view-only-send")

    # The second click of a double click is held for a moment, so ruling the next one waits it out.
    Process.sleep(400)
    view |> element("#decide-skip-send-twice") |> render_click()
    assert has_element?(view, "#review-finding-footer", "1 to fix · 1 not fixing")
    assert has_element?(view, "#review-tray-finding-view-only-send", "A view-only member can send diff comments")
    refute has_element?(view, "#review-tray-finding-send-twice")
    refute has_element?(view, "#send-review-tray[disabled]")

    expect(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: %{spawned | status: :running}}} end)
    view |> element("#send-review-tray", "Send 1") |> render_click()

    assert %{stage_outcome: :in_progress} = Repo.reload!(run)
  end

  # Comments stay open until cleanup: past Review they resume the lead on them alone, with no ruling or Finish review.
  test "at Finalize and after the merge a comment waits in the tray with Send, which resumes the lead, never Finish review",
       %{conn: conn, user: user, task: task, run: %{id: run_id, role_id: role_id} = run, code: code} do
    {:ok, _finding} = Pipeline.save_finding(task, Map.put(code, :key, "view-only-send"))
    {:ok, _pass} = Pipeline.save_review(task)
    {:ok, finalizing} = Pipeline.update_task(task, %{stage: :finalize, pr_number: 31})
    diff = %{path: "lib/a.ex", line_kind: :added, line: 3, line_text: "x = 1", filter: :branch}
    {:ok, _comment} = Pipeline.create_diff_comment(user_scope(user: user), task, Map.put(diff, :body, "Name it."))

    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}?tab=#{role_id}")
    assert has_element?(view, "#send-review-tray", "Send 1")
    refute has_element?(view, "#send-review-tray[disabled]")
    refute has_element?(view, "#finish-review")
    refute has_element?(view, "#decide-fix-view-only-send")

    expect(Tools, :start_os_process, fn %{id: ^run_id} = spawned, ["-p", prompt | _rest] ->
      assert prompt =~ "on the human's 1 comment."
      {:ok, %OsProcess{run: spawned}}
    end)

    view |> element("#send-review-tray", "Send 1") |> render_click()
    assert %{stage: :finalize} = Repo.reload!(task)

    # Once the lead's turn is over, nothing is left to send, and the tray draws nothing rather than Finish review.
    {:ok, _idle} = Pipeline.update_run(Repo.reload!(run), %{status: :finished})
    {:ok, merged} = Pipeline.update_task(finalizing, %{stage: :merged, merged_at: DateTime.utc_now()})
    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}?tab=#{role_id}")
    refute has_element?(view, "#review-send-tray")

    {:ok, _again} = Pipeline.create_diff_comment(user_scope(user: user), task, Map.put(diff, :body, "And this."))
    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}?tab=#{role_id}")
    assert has_element?(view, "#send-review-tray", "Send 1")

    {:ok, _cleaned} = Pipeline.update_task(merged, %{cleaned_up_at: DateTime.utc_now()})
    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}?tab=#{role_id}")
    refute has_element?(view, "#review-send-tray")
  end

  test "the tray reads Finish review when every finding is ruled Don't fix, and it and the rulings are gone once finished",
       %{conn: conn, task: task, run: run, code: code} do
    {:ok, finding} = Pipeline.save_finding(task, Map.put(code, :key, "view-only-send"))
    {:ok, _pass} = Pipeline.save_review(task)
    {:ok, _ruled} = Pipeline.decide_finding(system_scope(), finding, :skip)

    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
    assert has_element?(view, "#review-send-tray", "Nothing to send")
    assert has_element?(view, "#review-send-tray-hint", "Nothing to fix. Finish review closes the review.")
    assert has_element?(view, "#decide-fix-view-only-send")

    view |> element("#finish-review") |> render_click()
    # The stage hands the tray its gate through the page, which queues behind a render already asked for.
    _settled = render(view)

    # The page follows the task on to Finalize, whose conversation keeps no Finish review from the tab it left, and
    # the Review tab behind it reads finished.
    assert has_element?(view, "#task-tab-finalize[aria-selected=true]")
    refute has_element?(view, "#finish-review")
    view |> element("#task-tab-#{run.role_id}") |> render_click()

    refute has_element?(view, "#review-send-tray")
    refute has_element?(view, "#decide-fix-view-only-send")
    refute has_element?(view, "#decide-skip-view-only-send")
    assert has_element?(view, "#review-status[data-phase=finished]", "Nothing left to rule")
    assert has_element?(view, "#review-item-findings [data-qa=review_item_done]")
    assert has_element?(view, "#task-status-chip", "Ready to finalize")
  end

  # A chat turn that stopped or failed leaves the lead in progress, which Finish review settles.
  test "Finish review after a failed chat turn reads finished on the header", %{
    conn: conn,
    task: task,
    run: run,
    code: code
  } do
    {:ok, finding} = Pipeline.save_finding(task, Map.put(code, :key, "view-only-send"))
    {:ok, _pass} = Pipeline.save_review(task)
    {:ok, _ruled} = Pipeline.decide_finding(system_scope(), finding, :skip)
    {:ok, _failed} = Pipeline.update_run(run, %{stage_outcome: :in_progress, error: "The turn failed."})

    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
    assert has_element?(view, "#task-status-chip", "Review failed")

    view |> element("#finish-review") |> render_click()
    _settled = render(view)

    assert has_element?(view, "#task-status-chip", "Ready to finalize")
    refute has_element?(view, "#task-status-chip", "Review failed")
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

  test "a comment written on a piece of a finding shows under it and in the tray, and leaves both once sent", %{
    conn: conn,
    task: task,
    run: run,
    code: code
  } do
    {:ok, finding} = Pipeline.save_finding(task, Map.put(code, :key, "view-only-send"))
    {:ok, _pass} = Pipeline.save_review(task)
    {:ok, _ruled} = Pipeline.decide_finding(system_scope(), finding, :skip)

    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
    view |> element("[data-qa=finding_place]:nth-child(2) [data-qa=finding_comment_add]") |> render_click()
    view |> form("#finding-comment-form", %{"body" => "   "}) |> render_submit()
    assert has_element?(view, "[data-qa=finding_place]:nth-child(2) #finding-comment-form")

    view |> form("#finding-comment-form", %{"body" => "It is the caller too."}) |> render_change()
    view |> form("#finding-comment-form", %{"body" => "It is the caller too."}) |> render_submit()

    refute has_element?(view, "#finding-comment-form")

    assert has_element?(
             view,
             "[data-qa=finding_place]:nth-child(2) [data-qa=document_comment]",
             "It is the caller too."
           )

    assert has_element?(view, "#review-send-tray [data-kind=finding]", "Place 2, send_diff_comments/2")
    assert has_element?(view, "#review-send-tray [data-kind=finding]", "It is the caller too.")
    assert has_element?(view, "#send-review-tray", "Send 1")

    expect(Tools, :start_os_process, fn spawned, ["-p", prompt | _rest] ->
      assert prompt =~ "lib/rail/pipeline/actions/send_diff_comments.ex:22"
      assert prompt =~ "It is the caller too."
      {:ok, %OsProcess{run: %{spawned | status: :running}}}
    end)

    view |> element("#send-review-tray", "Send 1") |> render_click()
    _settled = render(view)

    refute has_element?(view, "#review-finding-detail [data-qa=document_comment]")
    refute has_element?(view, "#review-send-tray [data-kind=finding]")
    assert %{stage_outcome: :in_progress} = Repo.reload!(run)
  end

  test "a finding comment's box cancels, closes on another finding, and Remove takes a comment out", %{
    conn: conn,
    user: user,
    task: task,
    code: code,
    screen: screen
  } do
    {:ok, finding} = Pipeline.save_finding(task, Map.put(code, :key, "view-only-send"))
    {:ok, _other} = Pipeline.save_finding(task, Map.put(screen, :key, "send-twice"))
    {:ok, _pass} = Pipeline.save_review(task)

    {:ok, _comment} =
      Pipeline.create_finding_comment(user_scope(user: user), task, %{
        "finding_id" => finding.id,
        "piece" => "title",
        "body" => "Say who."
      })

    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
    view |> element("#finding-view-only-send") |> render_click()
    assert has_element?(view, "[data-qa=finding_title_comments] [data-qa=document_comment]", "Say who.")

    view |> element("[data-qa=finding_rule_text] [data-qa=finding_comment_add]") |> render_click()
    view |> element("#finding-comment-form [data-qa=finding_comment_cancel]") |> render_click()
    refute has_element?(view, "#finding-comment-form")

    # A piece this finding does not have, or a stale page's, opens nothing.
    for params <- [%{"piece" => "place", "index" => "7"}, %{"piece" => "verdict"}] do
      view |> with_target("#review-stage") |> render_click("open_finding_comment", params)
      refute has_element?(view, "#finding-comment-form")
    end

    view |> element("[data-qa=finding_rule_text] [data-qa=finding_comment_add]") |> render_click()
    view |> element("#finding-send-twice") |> render_click()
    refute has_element?(view, "#finding-comment-form")
    refute has_element?(view, "[data-qa=finding_title_comments] [data-qa=document_comment]")

    view |> element("#finding-view-only-send") |> render_click()
    view |> element("[data-qa=finding_title_comments] [data-qa=document_comment_remove]") |> render_click()
    refute has_element?(view, "[data-qa=finding_title_comments] [data-qa=document_comment]")
    refute has_element?(view, "#review-send-tray [data-kind=finding]")

    view |> with_target("#review-stage") |> render_click("remove_finding_comment", %{"id" => "fcm_gone"})
    view |> with_target("#review-stage") |> render_click("save_finding_comment", %{"body" => "No box."})
    view |> with_target("#review-stage") |> render_click("change_finding_comment", %{"body" => "No box."})
    assert Pipeline.list_finding_comments(user_scope(user: user), task) == []
  end

  test "a finding comment a task that moved on refuses says why, and closes the box", %{
    conn: conn,
    task: task,
    code: code
  } do
    {:ok, _finding} = Pipeline.save_finding(task, Map.put(code, :key, "view-only-send"))
    {:ok, _pass} = Pipeline.save_review(task)

    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    for {reason, said} <- [
          cleaned_up: "This task is cleaned up, so it takes no more comments.",
          not_found: "That finding has no such piece to comment on."
        ] do
      view |> element("[data-qa=finding_fix] [data-qa=finding_comment_add]") |> render_click()
      expect(Pipeline, :create_finding_comment, fn _scope, _task, _attrs -> {:error, reason} end)
      view |> form("#finding-comment-form", %{"body" => "Fold it."}) |> render_submit()

      assert has_element?(view, "#review-error", said)
      refute has_element?(view, "#finding-comment-form")
    end
  end

  test "a task that has left Review offers no + on its findings", %{conn: conn, task: task, code: code} do
    {:ok, _finding} = Pipeline.save_finding(task, Map.put(code, :key, "view-only-send"))
    {:ok, _pass} = Pipeline.save_review(task)
    {:ok, _cleaned} = Pipeline.update_task(task, %{cleaned_up_at: DateTime.utc_now()})

    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    assert has_element?(view, "[data-qa=finding_fix]")
    refute has_element?(view, "[data-qa=finding_comment_add]")
  end

  # The cleanup takes the passes with the scratch folder, and the task refuses comments.
  test "a cleaned-up task at Review draws no tray", %{conn: conn, task: task, run: run} do
    {:ok, _pass} = Pipeline.save_review(task)
    File.rm_rf!(task.scratch_path)
    {:ok, _cleaned} = Pipeline.update_task(task, %{cleaned_up_at: DateTime.utc_now()})

    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}?tab=#{run.role_id}")

    assert has_element?(view, "#review-stage")
    refute has_element?(view, "#review-send-tray")
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
    refute has_element?(view, "#finish-review")
    assert has_element?(view, "#review-send-tray-hint", "The Review lead is working. Send waits until it stops.")
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
    refute has_element?(view, "#finish-review")

    {:ok, _failed} = ci |> OsProcess.changeset(%{status: :finished, exit_code: 1}) |> Repo.update()
    {:ok, _stopped} = Pipeline.update_run(run, %{status: :finished, ci_failure_streak: 3, error: "CI failed 3 times"})
    send(view.pid, {:pipeline_changed, task.id})

    assert has_element?(view, "#review-status[data-phase=ci_failed]", "CI failed 3 times on fix round 1")
    assert has_element?(view, "#review-item-findings [data-qa=review_item_failed]")
  end

  test "with every finding fixed, Finish review waits on a fix commit CI failed", %{
    conn: conn,
    project: project,
    task: task,
    run: run,
    head: head,
    code: code
  } do
    {:ok, _project} = Projects.update_project(system_scope(), project, %{ci_command: "mise run ci"})
    {:ok, finding} = Pipeline.save_finding(task, Map.put(code, :key, "view-only-send"))
    {:ok, _pass} = Pipeline.save_review(task)
    {:ok, _ruled} = Pipeline.decide_finding(system_scope(), finding, :fix)

    {:ok, %Finding{status: :fixed}} =
      Pipeline.save_finding(task, %{
        key: "view-only-send",
        status: "fixed",
        covered: [1, 2],
        test: %{file: "test/send_test.exs", name: "checks the role"}
      })

    {:ok, _stopped} = Pipeline.update_run(run, %{ci_failure_streak: 3, error: "CI failed 3 times"})

    {:ok, _failed} =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: task.id,
        kind: :ci,
        command: "mise run ci",
        stream_path: Path.join(System.tmp_dir!(), "rst_ci_failed_#{run.id}.log"),
        status: :finished,
        exit_code: 1,
        head_sha: head,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert()

    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    assert has_element?(view, "#review-status[data-phase=ci_failed]")
    assert has_element?(view, "#finish-review[disabled]")
    assert has_element?(view, "#review-send-tray-hint", "CI failed on the fix commit")
  end

  test "Finish review on a commit CI has not passed says so", %{conn: conn, project: project, task: task, code: code} do
    {:ok, _project} = Projects.update_project(system_scope(), project, %{ci_command: "mise run ci"})
    {:ok, finding} = Pipeline.save_finding(task, Map.put(code, :key, "view-only-send"))
    {:ok, _pass} = Pipeline.save_review(task)
    {:ok, _ruled} = Pipeline.decide_finding(system_scope(), finding, :skip)

    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
    view |> element("#finish-review:not([disabled])") |> render_click()

    assert has_element?(
             view,
             "#review-send-tray-hint",
             "CI has not passed on the fix commit, so the review cannot finish yet."
           )

    assert has_element?(view, "#finish-review")
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

    # The Fix finding went out with the Send; the tray has nothing of it to send, and nothing to finish, mid-round.
    for ci <- [nil, %{state: :running, os_process: %OsProcess{head_sha: nil}, failures: 0, tail: []}] do
      stub(Pipeline, :get_ci_status, fn _run -> ci end)
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      refute has_element?(view, "#review-tray-finding-view-only-send")
      assert has_element?(view, "#review-send-tray", "Nothing to send")
      refute has_element?(view, "#send-review-tray")
      refute has_element?(view, "#finish-review")
      assert has_element?(view, "#review-send-tray-hint", "The Review lead is working. Send waits until it stops.")
    end

    # The engineer commits before the lead saves the finding fixed, so HEAD moves past the pass mid-round.
    stub(Pipeline, :get_ci_status, fn _run -> nil end)
    git!(task.worktree_path, ["commit", "--allow-empty", "-m", "Fix round 1"])
    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    refute has_element?(view, "#review-tray-finding-view-only-send")
    assert has_element?(view, "#review-send-tray", "Nothing to send")

    # A round that ends with the finding still not fixed puts it back in the tray.
    {:ok, _stopped} = run |> Repo.reload!() |> Pipeline.update_run(%{status: :finished})
    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    assert has_element?(view, "#review-tray-finding-view-only-send")
    assert has_element?(view, "#send-review-tray:not([disabled])", "Send 1")
  end

  test "the next round's status names the commit it re-reviews", %{conn: conn, task: task, run: run} do
    {:ok, _pass} = Pipeline.save_review(task)
    git!(task.worktree_path, ["commit", "--allow-empty", "-m", "Fix round 1"])
    head = task.worktree_path |> git!(["rev-parse", "HEAD"]) |> String.trim()
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

    assert has_element?(
             view,
             "[data-qa=review_browser_line]",
             "Watch only while Review drives it · signed in as explorer-1@rail.test"
           )

    view |> element("#review-browser-demo") |> render_click()

    assert has_element?(view, "#review-browser-demo[aria-pressed=true]")

    assert has_element?(
             view,
             "[data-qa=review_browser_line]",
             "Recording · 2 beats said so far · signed in as demo@rail.test"
           )

    assert has_element?(view, "#review-screencast-demo")
  end

  test "the picked browser is watch only while a run is in flight, and takes input once it has finished", %{
    conn: conn,
    task: task,
    run: run
  } do
    Repo.insert!(%BrowserSession{
      task_id: task.id,
      name: "explorer-1",
      account: "explorer-1@rail.test",
      status: :running,
      started_at: DateTime.utc_now()
    })

    {:ok, running} = Pipeline.update_run(run, %{status: :running, stage_outcome: :in_progress})
    test_pid = self()
    stub(Tools, :get_browser_session, fn _task, "explorer-1" -> test_pid end)
    stub(Tools, :get_browser_url, fn _task, _name -> "localhost:4012/tasks" end)

    stub(Rail.Tools.BrowserSession, :call, fn _session, method, params ->
      send(test_pid, {:cdp, method, params})
      {:ok, %{}}
    end)

    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
    view |> element("#review-item-browser") |> render_click()

    assert has_element?(view, "#review-browser-mode", "Watch only while Review drives it")
    assert has_element?(view, "#review-browser-frame[data-interactive=false]")

    view |> with_target("#review-stage") |> render_hook("browser_input", %{"type" => "click", "x" => 5, "y" => 5})
    refute_received {:cdp, _method, _params}

    {:ok, _finished} = Pipeline.update_run(running, %{status: :finished, stage_outcome: :done})
    send(view.pid, :task_changed)

    assert has_element?(view, "#review-browser-mode", "Click and type to use it · signed in as explorer-1@rail.test")
    assert has_element?(view, "#review-browser-frame[data-interactive=true][tabindex='0']")

    view |> with_target("#review-stage") |> render_hook("browser_input", %{"type" => "click", "x" => 5, "y" => 5})
    assert_received {:cdp, "Input.dispatchMouseEvent", %{type: "mousePressed", x: 5, y: 5}}
  end

  # Rail restarted since the round, so nothing holds the tab; opening the browser attaches to it, never a new one.
  test "opening a browser whose session went with a restart attaches to its tab", %{conn: conn, task: task} do
    Repo.insert!(%BrowserSession{task_id: task.id, name: "explorer-1", status: :running, started_at: DateTime.utc_now()})
    test_pid = self()

    expect(Tools, :start_browser_session, fn _task, "explorer-1", [existing: true] ->
      send(test_pid, :attached)
      {:ok, self()}
    end)

    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
    view |> element("#review-item-browser") |> render_click()
    assert_receive :attached, 2_000

    # Once a page, however often the item redraws.
    view |> element("#review-item-findings") |> render_click()
    view |> element("#review-item-browser") |> render_click()
    _settled = render(view)
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
    refute has_element?(view, "#review-send-tray")
    refute has_element?(view, "#decide-fix-view-only-send")
  end

  test "a fix round that is refused says why", %{conn: conn, task: task, code: code} do
    {:ok, finding} = Pipeline.save_finding(task, Map.put(code, :key, "view-only-send"))
    {:ok, _pass} = Pipeline.save_review(task)
    {:ok, _ruled} = Pipeline.decide_finding(system_scope(), finding, :fix)
    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    for {reason, said} <- [
          nothing_to_start: "There is nothing to send: the review is finished.",
          dispatch_disabled: "Dispatch is off, so the Review lead was not resumed.",
          stage_running: "The Review lead is working. Send waits until it stops.",
          findings_undecided: "Some findings have no ruling yet. Rule on every one first.",
          invalid_stage: "This task is at Merged, not Review."
        ] do
      error = if reason == :invalid_stage, do: {:invalid_stage, :merged}, else: reason
      expect(Pipeline, :start_fix_round, fn _scope, _run -> {:error, error} end)
      view |> element("#send-review-tray") |> render_click()

      assert has_element?(view, "#review-send-tray-hint", said)
    end
  end

  # The page hides Fix and Don't fix once the review finishes, so only a ruling made as it finishes is refused.
  test "a ruling that is refused says why", %{conn: conn, task: task, code: code} do
    {:ok, _finding} = Pipeline.save_finding(task, Map.put(code, :key, "view-only-send"))
    {:ok, _pass} = Pipeline.save_review(task)
    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    expect(Pipeline, :decide_finding, fn _scope, _finding, :fix -> {:error, :review_finished} end)
    view |> element("#decide-fix-view-only-send") |> render_click()

    assert has_element?(view, "#review-error", "The review is finished, so its rulings are settled.")
  end

  describe "with the branch's commits" do
    # The branch forked from origin/main at the first commit, then the engineer committed, round 1 read it,
    # and the fix round it led to committed.
    setup %{task: %{worktree_path: worktree} = task} do
      git!(worktree, ["update-ref", "refs/remotes/origin/main", "HEAD"])
      File.write!(Path.join(worktree, "a.ex"), "defmodule A do\nend\n")
      git!(worktree, ["add", "."])
      git!(worktree, ["commit", "-m", "Send comments as one round"])
      engineer = worktree |> git!(["rev-parse", "HEAD"]) |> String.trim()
      {:ok, %{round: 1}} = Pipeline.save_review(task)
      File.write!(Path.join(worktree, "b.ex"), "defmodule B do\nend\n")
      git!(worktree, ["add", "."])
      git!(worktree, ["commit", "-m", "Fix 1 finding from round 1"])
      fix = worktree |> git!(["rev-parse", "HEAD"]) |> String.trim()

      %{engineer: engineer, fix: fix}
    end

    test "the Diff item counts the commits and lines, and opens on the whole branch", %{conn: conn, task: task} do
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "#review-item-diff[title='Diff: 2 commits · +4 -0']")

      view |> element("#review-item-diff") |> render_click()

      assert has_element?(view, "#review-pane[data-item=diff] #diff-commit-picker", "Whole branch")
      assert has_element?(view, "[data-qa='diff_file_section'][data-path='a.ex']")
      assert has_element?(view, "[data-qa='diff_file_section'][data-path='b.ex']")
    end

    # Round 1 read the fix commit, which never touched a.ex, so Raised in lands on the branch that has it.
    test "Raised in, Fixed in and Open in Diff open their commit at the finding's file, or the branch without it", %{
      conn: conn,
      task: task,
      code: code,
      engineer: engineer
    } do
      {:ok, finding} = Pipeline.save_finding(task, Map.put(%{code | file: "a.ex", line: 1}, :key, "view-only-send"))
      {:ok, _fixed} = finding |> Ecto.Changeset.change(fixed_in: engineer) |> Repo.update()
      {:ok, _pass} = Pipeline.save_review(task)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      view |> element("[data-qa=finding_raised_in] [data-qa=finding_commit_link]") |> render_click()

      assert has_element?(view, "#review-pane[data-item=diff] #diff-commit-picker", "Whole branch")
      assert has_element?(view, "#diff-scroller[data-scroll-to='a.ex']")
      assert has_element?(view, "[data-qa='diff_file_section'][data-path='a.ex']")

      view |> element("#review-item-findings") |> render_click()
      view |> element("[data-qa=finding_fixed_in] [data-qa=finding_commit_link]") |> render_click()

      assert has_element?(view, "#diff-commit-picker", "Implement")
      assert has_element?(view, "[data-qa='diff_file_section'][data-path='a.ex']")
      refute has_element?(view, "[data-qa='diff_file_section'][data-path='b.ex']")

      # A commit the branch does not have, after a rebase say, opens the whole branch.
      view |> with_target("#review-stage") |> render_click("open_diff", %{"commit" => String.duplicate("0", 40)})

      assert has_element?(view, "#diff-commit-picker", "Whole branch")
    end

    test "the Screens item shows each state's one shot, and the screen view steps through them in the grid's order", %{
      conn: conn,
      task: %{worktree_path: worktree} = task,
      screen: screen
    } do
      {:ok, %{round: 2}} = Pipeline.save_review(task)
      git!(worktree, ["commit", "--allow-empty", "-m", "Fix 1 finding from round 2"])
      latest = worktree |> git!(["rev-parse", "HEAD"]) |> String.trim()

      for {key, label} <- [{"toolbar", "Toolbar"}, {"file-list-after-send", "File list just after Send"}] do
        File.mkdir_p!(Path.join([task.scratch_path, "qa", "screens", key]))
        File.write!(Path.join([task.scratch_path, "qa", "screens", key, "1.jpg"]), "jpeg")
        {:ok, _shot} = Pipeline.save_screen(task, %{key: key, label: label, file: "screens/#{key}/1.jpg"})
      end

      {:ok, _cited} =
        Pipeline.save_finding(
          task,
          screen
          |> Map.put(:key, "send-twice")
          |> Map.put(:evidence, [%{name: "The list", kind: :screenshot, path: "screens/file-list-after-send/1.jpg"}])
        )

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "#review-item-screens[title='Screens: 2 screens · on #{String.slice(latest, 0, 7)}']")

      view |> element("#review-item-screens") |> render_click()

      assert has_element?(view, "[data-qa=review_screens_count]", "2")
      assert has_element?(view, "[data-qa=review_screens_on]", "latest taken on #{String.slice(latest, 0, 7)}")
      assert has_element?(view, "#screen-file-list-after-send", "Fix round 2")
      refute has_element?(view, "#screen-file-list-after-send", "earlier")

      assert has_element?(
               view,
               "#screen-file-list-after-send img[src^='/tasks/#{task.id}/screens/file-list-after-send?at=']"
             )

      view |> element("#screen-file-list-after-send") |> render_click()

      assert has_element?(view, "#screen-view-position", "1 of 2")
      assert has_element?(view, "#screen-view-name", "File list just after Send")
      assert has_element?(view, "#screen-view-previous[aria-disabled=true]")

      view |> element("#screen-view-next") |> render_click()
      assert has_element?(view, "#screen-view-name", "Toolbar")
      assert has_element?(view, "#screen-view-next[aria-disabled=true]")
      view |> element("#screen-view-next") |> render_click()
      assert has_element?(view, "#screen-view-name", "Toolbar")

      view |> element("#screen-view-panel") |> render_keydown(%{"key" => "ArrowLeft"})
      assert has_element?(view, "#screen-view-name", "File list just after Send")
      view |> element("#screen-view-panel") |> render_keydown(%{"key" => "ArrowLeft"})
      view |> element("#screen-view-panel") |> render_keydown(%{"key" => "Enter"})
      assert has_element?(view, "#screen-view-position", "1 of 2")
      view |> element("#screen-view-panel") |> render_keydown(%{"key" => "ArrowRight"})
      assert has_element?(view, "#screen-view-position", "2 of 2")
      view |> element("#screen-view-previous") |> render_click()

      # While the comment box is open the arrow keys are the box's.
      view |> element("#screen-view-comment") |> render_click()
      assert has_element?(view, "#screen-view-comment[aria-pressed=true]")
      refute has_element?(view, "#screen-view-panel[phx-window-keydown]")
      view |> with_target("#review-stage") |> render_hook("screen_key", %{"key" => "ArrowRight"})
      assert has_element?(view, "#screen-view-name", "File list just after Send")
      view |> element("#screen-comment-form [data-qa=screen_comment_cancel]") |> render_click()
      assert has_element?(view, "#screen-view-panel[phx-window-keydown]")

      view |> element("#screen-view-close") |> render_click()
      refute has_element?(view, "#screen-view")
      assert has_element?(view, "#screen-file-list-after-send")

      view |> element("#screen-file-list-after-send") |> render_click()
      view |> element("[data-qa=screen_finding]", "Send stays enabled") |> render_click()
      refute has_element?(view, "#screen-view")
      assert has_element?(view, "#review-pane[data-item=findings]")
      assert has_element?(view, "[data-qa=review_finding_detail]", "Send stays enabled")
    end

    test "a comment saved in the screen view shows there, on its card and in the tray, also after Finish review", %{
      conn: conn,
      task: task,
      run: run
    } do
      File.mkdir_p!(Path.join([task.scratch_path, "qa", "screens", "toolbar"]))
      File.write!(Path.join([task.scratch_path, "qa", "screens", "toolbar", "1.jpg"]), "jpeg")
      {:ok, _shot} = Pipeline.save_screen(task, %{key: "toolbar", label: "Toolbar", file: "screens/toolbar/1.jpg"})
      {:ok, %{round: 2}} = Pipeline.save_review(task)
      {:ok, _finished} = Pipeline.start_fix_round(system_scope(), run)

      # The finished review moved the task on to Finalize, and its Review tab still takes comments.
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}?tab=#{run.role_id}")
      refute has_element?(view, "#review-send-tray")
      view |> element("#review-item-screens") |> render_click()
      view |> element("#screen-toolbar") |> render_click()
      view |> element("#screen-view-comment") |> render_click()
      view |> form("#screen-comment-form", %{"body" => "   "}) |> render_submit()
      assert has_element?(view, "#screen-comment-form")
      view |> form("#screen-comment-form", %{"body" => "The count wraps."}) |> render_change()
      view |> form("#screen-comment-form", %{"body" => "The count wraps."}) |> render_submit()

      refute has_element?(view, "#screen-comment-form")
      assert has_element?(view, "#screen-view [data-qa=screen_comment]", "The count wraps.")
      assert has_element?(view, "#screen-toolbar [data-qa=screen_card_unsent]", "1 not sent")
      assert has_element?(view, "#review-send-tray [data-kind=screen]", "The count wraps.")

      assert has_element?(
               view,
               "#review-send-tray-hint",
               "The review is finished. Send reopens it with a fix round on your comments."
             )

      expect(Tools, :start_os_process, fn spawned, ["-p", prompt | _rest] ->
        assert prompt =~ "The count wraps."
        {:ok, %OsProcess{run: %{spawned | status: :running}}}
      end)

      view |> element("#send-review-tray", "Send 1") |> render_click()
      _settled = render(view)

      refute has_element?(view, "#screen-view [data-qa=screen_comment]")
      refute has_element?(view, "[data-qa=screen_card_unsent]")
      assert has_element?(view, "#review-item-findings[title='Findings: Fix round 2 running']")
    end

    test "Remove takes a comment out of the screen view, and a state a retake took away closes it", %{
      conn: conn,
      task: task,
      user: user
    } do
      File.mkdir_p!(Path.join([task.scratch_path, "qa", "screens", "toolbar"]))
      File.write!(Path.join([task.scratch_path, "qa", "screens", "toolbar", "1.jpg"]), "jpeg")
      {:ok, _shot} = Pipeline.save_screen(task, %{key: "toolbar", label: "Toolbar", file: "screens/toolbar/1.jpg"})

      {:ok, _comment} =
        Pipeline.create_screen_comment(user_scope(user: user), task, %{"key" => "toolbar", "body" => "Hi."})

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      view |> element("#review-item-screens") |> render_click()
      view |> element("#screen-toolbar") |> render_click()
      view |> element("#screen-view [data-qa=screen_comment_remove]") |> render_click()

      refute has_element?(view, "#screen-view [data-qa=screen_comment]")
      view |> with_target("#review-stage") |> render_click("remove_screen_comment", %{"id" => "scm_gone"})

      File.rm_rf!(Path.join([task.scratch_path, "qa", "screens"]))
      send(view.pid, {:output_saved, task.id})
      _settled = render(view)

      refute has_element?(view, "#screen-view")
    end

    test "a saved comment a task that moved on refuses says why", %{conn: conn, task: task} do
      File.mkdir_p!(Path.join([task.scratch_path, "qa", "screens", "toolbar"]))
      File.write!(Path.join([task.scratch_path, "qa", "screens", "toolbar", "1.jpg"]), "jpeg")
      {:ok, _shot} = Pipeline.save_screen(task, %{key: "toolbar", label: "Toolbar", file: "screens/toolbar/1.jpg"})

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      view |> element("#review-item-screens") |> render_click()
      view |> element("#screen-toolbar") |> render_click()
      view |> element("#screen-view-comment") |> render_click()

      for {reason, said} <- [
            cleaned_up: "This task is cleaned up, so it takes no more comments.",
            not_found: "That screen is gone: a retake or a cleanup removed it."
          ] do
        expect(Pipeline, :create_screen_comment, fn _scope, _task, _attrs -> {:error, reason} end)
        view |> form("#screen-comment-form", %{"body" => "Fold it."}) |> render_submit()

        assert has_element?(view, "#review-error", said)
      end
    end

    # A Send of comments alone resumes the lead on the commit the last pass read.
    test "a round working on the commit the last pass read is a fix round, with no Fix finding", %{
      conn: conn,
      task: task,
      run: run
    } do
      {:ok, %{round: 2}} = Pipeline.save_review(task)
      {:ok, _working} = Pipeline.update_run(run, %{status: :running})

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "#review-status[data-phase=fixing]")
    end

    test "with no screens the Screens item says so, and a state a stale page names opens nothing", %{
      conn: conn,
      task: task
    } do
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      view |> element("#review-item-screens") |> render_click()

      assert has_element?(view, "[data-qa=review_screens_count]", "0")
      assert has_element?(view, "[data-qa=review_screens_none]", "No screens yet.")
      refute has_element?(view, "[data-qa=review_screens_on]")

      view |> with_target("#review-stage") |> render_click("open_screen", %{"key" => "gone"})

      assert has_element?(view, "[data-qa=review_screens_none]")
    end

    # Its worktree cleaned up, the branch has nothing on disk left to diff.
    test "the Diff item of a task whose worktree is gone says nothing has changed", %{conn: conn, task: task} do
      {:ok, _gone} = Pipeline.update_task(task, %{worktree_path: "/tmp/gone_#{System.unique_integer([:positive])}"})

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      view |> element("#review-item-diff") |> render_click()

      assert has_element?(view, "[data-qa=diff_empty_state]", "Nothing has been changed on this branch yet.")
    end

    test "a retake that lands while a state is open shows its new shot", %{conn: conn, task: task} do
      folder = Path.join([task.scratch_path, "qa", "screens", "toolbar"])
      File.mkdir_p!(folder)
      File.write!(Path.join(folder, "1.jpg"), "only")
      {:ok, _only} = Pipeline.save_screen(task, %{key: "toolbar", label: "Toolbar", file: "screens/toolbar/1.jpg"})

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      view |> element("#review-item-screens") |> render_click()
      view |> element("#screen-toolbar") |> render_click()

      assert has_element?(view, "#screen-view-picture-toolbar-1")
      refute has_element?(view, "#screen-view-position")

      File.write!(Path.join(folder, "2.jpg"), "retaken")
      {:ok, _retaken} = Pipeline.save_screen(task, %{key: "toolbar", label: "Toolbar", file: "screens/toolbar/2.jpg"})
      send(view.pid, {:output_saved, task.id})
      # The page redraws the stage through send_update, which queues behind a render already asked for.
      _settled = render(view)
      _settled = render(view)

      assert has_element?(view, "#screen-view-picture-toolbar-2")
    end

    test "a demo the branch has moved past says so in slate with Re-record, and the rail marks it", %{
      conn: conn,
      task: task,
      run: run,
      engineer: engineer,
      fix: fix
    } do
      demo_dir = Path.join(task.scratch_path, "demo")
      File.mkdir_p!(demo_dir)
      File.write!(Path.join(demo_dir, "demo.webm"), "webm")

      File.write!(
        Path.join(demo_dir, "RST-1.json"),
        Jason.encode!(%{title: "Filters", summary: "It filters.", commit: engineer})
      )

      short = String.slice(engineer, 0, 7)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "#review-item-demo[title='Demo: Recorded on #{short}, 1 commit ago; may be out of date']")
      assert has_element?(view, "#review-item-demo [data-qa=review_item_stale]")

      view |> element("#review-item-demo") |> render_click()

      assert has_element?(view, "#demo-stale button", short)
      assert has_element?(view, "#demo-stale", "1 commit ago; may be out of date")
      expect(Pipeline, :record_demo, fn _scope, _task -> {:ok, :sent, run} end)
      view |> element("#demo-rerecord") |> render_click()
      refute has_element?(view, "#review-error")

      expect(Pipeline, :record_demo, fn _scope, _task -> {:error, :stage_running} end)
      view |> element("#demo-rerecord") |> render_click()
      assert has_element?(view, "#review-error", "Something is still running on this task.")

      view |> element("#demo-stale button", short) |> render_click()
      assert has_element?(view, "#review-pane[data-item=diff] #diff-commit-picker", "Implement")

      File.write!(
        Path.join(demo_dir, "RST-1.json"),
        Jason.encode!(%{title: "Filters", summary: "It filters.", commit: fix})
      )

      {:ok, latest, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(latest, "#review-item-demo[title='Demo: Recorded on #{String.slice(fix, 0, 7)}']")
      refute has_element?(latest, "#review-item-demo [data-qa=review_item_stale]")
      latest |> element("#review-item-demo") |> render_click()
      refute has_element?(latest, "#demo-stale")
    end

    # A rebase leaves the branch without the commit the demo was recorded on, which is when it is most out of date.
    test "a demo on a commit the branch no longer has is stale, with nothing to open", %{
      conn: conn,
      task: %{worktree_path: worktree} = task
    } do
      git!(worktree, ["commit", "--allow-empty", "-m", "Rebased away"])
      gone = worktree |> git!(["rev-parse", "HEAD"]) |> String.trim()
      git!(worktree, ["reset", "--quiet", "--hard", "HEAD~1"])
      demo_dir = Path.join(task.scratch_path, "demo")
      File.mkdir_p!(demo_dir)
      File.write!(Path.join(demo_dir, "demo.webm"), "webm")

      File.write!(
        Path.join(demo_dir, "RST-1.json"),
        Jason.encode!(%{title: "Filters", summary: "It filters.", commit: gone})
      )

      short = String.slice(gone, 0, 7)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(
               view,
               "#review-item-demo[title='Demo: Recorded on #{short}, which the branch no longer has; may be out of date']"
             )

      assert has_element?(view, "#review-item-demo [data-qa=review_item_stale]")

      view |> element("#review-item-demo") |> render_click()

      assert has_element?(view, "[data-qa=demo_stale]", "Recorded on #{short}, which the branch no longer has")
      assert has_element?(view, "#demo-rerecord")
      refute has_element?(view, "#demo-stale button[phx-click=open_diff]")
    end

    test "a demo two commits behind counts them, and a Re-record Review cannot take says why", %{
      conn: conn,
      task: %{worktree_path: worktree} = task,
      engineer: engineer
    } do
      demo_dir = Path.join(task.scratch_path, "demo")
      File.mkdir_p!(demo_dir)
      File.write!(Path.join(demo_dir, "demo.webm"), "webm")

      File.write!(
        Path.join(demo_dir, "RST-1.json"),
        Jason.encode!(%{title: "Filters", summary: "It filters.", commit: engineer})
      )

      git!(worktree, ["commit", "--allow-empty", "-m", "later"])

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      view |> element("#review-item-demo") |> render_click()

      assert has_element?(view, "#demo-stale", "2 commits ago; may be out of date")

      for {reason, said} <- [
            no_stage_run: "Review has no run to ask yet.",
            chat_unavailable: "The Review lead has no conversation to ask yet."
          ] do
        expect(Pipeline, :record_demo, fn _scope, _task -> {:error, reason} end)
        view |> element("#demo-rerecord") |> render_click()

        assert has_element?(view, "#review-error", said)
      end
    end

    test "Re-record waits while the Review lead works", %{conn: conn, task: task, run: run, engineer: engineer} do
      demo_dir = Path.join(task.scratch_path, "demo")
      File.mkdir_p!(demo_dir)
      File.write!(Path.join(demo_dir, "demo.webm"), "webm")

      File.write!(
        Path.join(demo_dir, "RST-1.json"),
        Jason.encode!(%{title: "Filters", summary: "It filters.", commit: engineer})
      )

      {:ok, _working} = Pipeline.update_run(run, %{status: :running})

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      view |> element("#review-item-demo") |> render_click()

      assert has_element?(view, "#demo-rerecord[disabled]")
    end
  end
end
