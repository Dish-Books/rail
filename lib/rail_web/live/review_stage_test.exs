defmodule RailWeb.Live.ReviewStageTest do
  use RailWeb.ConnCase, async: true
  use Oban.Testing, repo: Rail.Repo

  import Phoenix.LiveViewTest

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.DemoBeat
  alias Rail.Pipeline.Schemas.Finding
  alias Rail.Pipeline.Schemas.Round
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Pipeline.Workers.StartEngineer
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

    {:ok, engineer_run} =
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

    %{
      conn: log_in_user(conn, user),
      user: user,
      task: task,
      run: run,
      engineer_run: engineer_run,
      head: head,
      code: code,
      screen: screen
    }
  end

  test "the rail shows the task's items, then Findings, Diff, Screens, Demo and Browser, each with its state as its title",
       %{
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

    assert ["issue", "plan", "conversation", "findings", "diff", "screens", "demo", "browser"] =
             view
             |> render()
             |> Floki.parse_document!()
             |> Floki.find("#review-items button")
             |> Enum.flat_map(&Floki.attribute(&1, "phx-value-item"))

    assert has_element?(view, "#review-item-findings .sr-only", "2 to rule")
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

  # An unruled finding goes to the round on the review agent's recommendation, so Send does not wait on a ruling.
  test "Send carries the findings to fix, unruled ones on their recommendation; ruling moves on to the next", %{
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

    assert has_element?(view, "#review-finding-footer", "2 to rule")
    refute has_element?(view, "#review-finding-footer button")
    refute has_element?(view, "#send-review-tray[disabled]")

    view |> element("#decide-fix-view-only-send") |> render_click()
    assert has_element?(view, "#finding-send-twice[aria-current=true]")
    assert %Finding{decision: :fix} = Repo.get_by!(Finding, task_id: task.id, key: "view-only-send")

    # The second click of a double click is held for a moment, so ruling the next one waits it out.
    Process.sleep(400)
    view |> element("#decide-skip-send-twice") |> render_click()
    assert has_element?(view, "#review-finding-footer", "1 to fix · 1 not fixing")
    assert has_element?(view, "#review-tray-finding-view-only-send", "A view-only member can send diff comments")
    refute has_element?(view, "#review-tray-finding-send-twice")

    expect(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: %{spawned | status: :running}}} end)
    view |> element("#send-review-tray", "Send 1") |> render_click()

    assert %{stage_outcome: :in_progress} = Repo.reload!(run)
  end

  # Comments stay open until cleanup: past Review they resume the lead on them alone, with no ruling or Finish review.
  test "at Finalize and after the merge a comment waits in the tray with Send, which resumes the lead, never Finish review",
       %{conn: conn, user: user, task: task, run: %{id: run_id} = run, code: code} do
    {:ok, _finding} = Pipeline.save_finding(task, Map.put(code, :key, "view-only-send"))
    {:ok, _pass} = Pipeline.save_review(task)
    {:ok, finalizing} = Pipeline.update_task(task, %{stage: :finalize, pr_number: 31})
    diff = %{path: "lib/a.ex", line_kind: :added, line: 3, line_text: "x = 1", filter: :branch}
    {:ok, _comment} = Pipeline.create_diff_comment(user_scope(user: user), task, Map.put(diff, :body, "Name it."))

    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
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
    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
    refute has_element?(view, "#review-send-tray")

    {:ok, _again} = Pipeline.create_diff_comment(user_scope(user: user), task, Map.put(diff, :body, "And this."))
    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
    assert has_element?(view, "#send-review-tray", "Send 1")

    {:ok, _cleaned} = Pipeline.update_task(merged, %{cleaned_up_at: DateTime.utc_now()})
    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
    refute has_element?(view, "#review-send-tray")
  end

  test "the tray reads Finish review when every finding is ruled Don't fix, and it and the rulings are gone once finished",
       %{conn: conn, task: task, code: code} do
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

    # The task moved on to Finalize and the page stays on Findings, which reads finished, with no Finish review.
    assert %{stage: :finalize} = Repo.reload!(task)
    refute has_element?(view, "#finish-review")

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
    assert has_element?(view, "#finding-places", "Applies in 2 places")
    assert has_element?(view, "#finding-places [data-qa=finding_place]", "send_diff_comments/2")
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
    view |> element("#finding-place-2 > [data-qa=finding_comment_add]") |> render_click()
    view |> form("#finding-comment-form", %{"body" => "   "}) |> render_submit()
    assert has_element?(view, "#finding-place-2 #finding-comment-form")

    view |> form("#finding-comment-form", %{"body" => "It is the caller too."}) |> render_change()
    view |> form("#finding-comment-form", %{"body" => "It is the caller too."}) |> render_submit()

    refute has_element?(view, "#finding-comment-form")

    assert has_element?(
             view,
             "#finding-place-2 [data-qa=document_comment]",
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
  test "a cleaned-up task at Review draws no tray", %{conn: conn, task: task} do
    {:ok, _pass} = Pipeline.save_review(task)
    File.rm_rf!(task.scratch_path)
    {:ok, _cleaned} = Pipeline.update_task(task, %{cleaned_up_at: DateTime.utc_now()})

    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

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

  # The agents at work are the task's running runs, each with the work its role does.
  test "while a round runs nothing asks for a call, and the status names the agents at work", %{
    conn: conn,
    project: project,
    task: task,
    run: run,
    code: code
  } do
    {:ok, _finding} = Pipeline.save_finding(task, Map.put(code, :key, "view-only-send"))
    {:ok, _run} = Pipeline.update_run(run, %{status: :running, stage_outcome: :in_progress})

    for stage <- [:qa, :review] do
      {:ok, role} = Roles.get_role(project_id: project.id, stage: stage)

      {:ok, _checking} =
        Pipeline.create_run(%{
          task_id: task.id,
          role_id: role.id,
          status: :running,
          conversation_id: "sess_rst_#{stage}",
          started_at: DateTime.utc_now()
        })
    end

    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    assert has_element?(view, "#review-status[data-phase=round]", "Round 1")
    assert has_element?(view, "[data-qa=review_status_agent]", "qa role")
    assert has_element?(view, "[data-qa=review_status_agent]", "Tests the running app")
    assert has_element?(view, "[data-qa=review_status_agent]", "review role")
    assert has_element?(view, "[data-qa=review_status_agent]", "Reads the diff")
    assert has_element?(view, "#review-item-findings [data-qa=review_item_running]")
    refute has_element?(view, "#finish-review")
    assert has_element?(view, "#review-send-tray-hint", "The Review lead is working. Send waits until it stops.")
    assert has_element?(view, "#review-finding-footer", "1 so far · rule once round 1 finishes")
    refute has_element?(view, "#decide-fix-view-only-send")
    refute has_element?(view, "[data-qa=review_finding_state]", "Needs your call")
  end

  # A fix round is the engineer's, so CI on its commit runs on the engineer's run with the task at Engineer.
  test "CI on the fix commit and CI failed three times show their headline and line, with no log", %{
    conn: conn,
    project: project,
    task: task,
    engineer_run: run,
    head: head
  } do
    {:ok, _project} = Projects.update_project(system_scope(), project, %{ci_command: "mise run ci"})
    {:ok, _pass} = Pipeline.save_review(task)
    {:ok, _fixing} = Pipeline.update_task(task, %{stage: :engineer})
    {:ok, run} = Pipeline.update_run(run, %{status: :running})
    log = Path.join(System.tmp_dir!(), "rst_ci_#{run.id}.log")
    File.write!(log, "==> rail\nCompiling 14 files (.ex)\nRunning ExUnit\n\n")
    on_exit(fn -> File.rm(log) end)

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

    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}?item=findings")
    short = String.slice(head, 0, 7)

    assert has_element?(view, "#review-status[data-phase=ci]", "CI running on #{short} · Fix round 1")
    refute has_element?(view, "[data-qa=review_status_log]")
    assert has_element?(view, "#review-item-findings[title='Findings: CI running on #{short}']")
    refute has_element?(view, "#finish-review")

    {:ok, _failed} = ci |> OsProcess.changeset(%{status: :finished, exit_code: 1}) |> Repo.update()
    {:ok, _stopped} = Pipeline.update_run(run, %{status: :finished, ci_failure_streak: 3, error: "CI failed 3 times"})
    send(view.pid, {:pipeline_changed, task.id})

    assert has_element?(view, "#review-status[data-phase=ci_failed]", "CI failed 3 times on fix round 1")
    assert has_element?(view, "[data-qa=review_status_body]", "Read the CI output in the conversation")
    refute has_element?(view, "[data-qa=review_status_log]")
    assert has_element?(view, "#review-item-findings [data-qa=review_item_failed]")
  end

  # CI fails on the engineer's run, at Engineer, where nothing is ruled or sent, so there is no Finish review.
  test "with every finding fixed, a fix commit CI failed three times reads failed and offers no Finish review", %{
    conn: conn,
    project: project,
    task: task,
    engineer_run: engineer_run,
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

    {:ok, _fixing} = Pipeline.update_task(task, %{stage: :engineer})
    {:ok, _stopped} = Pipeline.update_run(engineer_run, %{ci_failure_streak: 3, error: "CI failed 3 times"})

    {:ok, _failed} =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: engineer_run.id,
        task_id: task.id,
        kind: :ci,
        command: "mise run ci",
        stream_path: Path.join(System.tmp_dir!(), "rst_ci_failed_#{engineer_run.id}.log"),
        status: :finished,
        exit_code: 1,
        head_sha: head,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert()

    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}?item=findings")

    assert has_element?(view, "#review-status[data-phase=ci_failed]")
    refute has_element?(view, "#finish-review")
    refute has_element?(view, "#review-send-tray")
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

  # An approved fix plan moves the task to Engineer, whose run is the fix round.
  test "a fix round in progress says the engineer is fixing, and the footer counts what is being fixed", %{
    conn: conn,
    task: task,
    engineer_run: engineer_run,
    code: code
  } do
    {:ok, finding} = Pipeline.save_finding(task, Map.put(code, :key, "view-only-send"))
    {:ok, _pass} = Pipeline.save_review(task)
    {:ok, _ruled} = Pipeline.decide_finding(system_scope(), finding, :fix)
    {:ok, fixing} = Pipeline.update_task(task, %{stage: :engineer})
    {:ok, _working} = Pipeline.update_run(engineer_run, %{status: :running})

    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}?item=findings")

    assert has_element?(view, "#review-status[data-phase=fixing]", "Fix round 1 · Engineer fixing 1 finding")
    assert has_element?(view, "#review-finding-footer", "1 fixing")

    # The Fix finding went out with the Send, and mid-round, CI on the fix commit included, nothing is sent or finished.
    for ci <- [nil, %{state: :running, os_process: %OsProcess{head_sha: nil}, failures: 0, tail: []}] do
      stub(Pipeline, :get_ci_status, fn _run -> ci end)
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}?item=findings")

      refute has_element?(view, "#review-tray-finding-view-only-send")
      refute has_element?(view, "#send-review-tray")
      refute has_element?(view, "#finish-review")
    end

    # A round that ends with the finding still not fixed puts it back in the tray.
    stub(Pipeline, :get_ci_status, fn _run -> nil end)
    {:ok, _stopped} = engineer_run |> Repo.reload!() |> Pipeline.update_run(%{status: :finished})
    {:ok, _reviewing} = Pipeline.update_task(fixing, %{stage: :review})
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

  test "the URL names the item picked, without reading the task again", %{conn: conn, task: task} do
    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
    reject(&Pipeline.get_task/1)

    for item <- ["diff", "screens", "demo", "browser"] do
      view |> element("#review-item-#{item}") |> render_click()
      assert_patch(view, ~p"/tasks/#{task.id}?item=#{item}")
      assert has_element?(view, "#review-pane[data-item=#{item}]")
    end

    view |> element("#review-item-findings") |> render_click()
    assert_patch(view, ~p"/tasks/#{task.id}?item=findings")
    assert has_element?(view, "#review-pane[data-item=findings]")

    # The item already open is where the URL already is.
    view |> element("#review-item-findings") |> render_click()
    _settled = render(view)
    refute_patched(view)
  end

  test "a URL naming an item opens Review on it, and one naming none or an unknown one opens Findings", %{
    conn: conn,
    task: task
  } do
    {:ok, view, html} = live(conn, ~p"/tasks/#{task.id}?item=demo")
    assert html =~ ~s(data-item="demo")
    assert has_element?(view, "#review-item-demo[aria-current=true]")
    assert has_element?(view, "#review-pane[data-item=demo]")

    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}?item=whatever")
    assert has_element?(view, "#review-pane[data-item=findings]")

    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
    assert has_element?(view, "#review-pane[data-item=findings]")
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

  test "a code finding brackets its whole range, and no line outside it or replaced", %{
    conn: conn,
    task: %{worktree_path: worktree} = task,
    code: code
  } do
    File.write!(Path.join(worktree, "example.ex"), Enum.map_join(1..12, "", &"line #{&1}\n"))
    git!(worktree, ["add", "."])
    git!(worktree, ["commit", "-m", "before"])
    git!(worktree, ["update-ref", "refs/remotes/origin/main", "HEAD"])

    File.write!(
      Path.join(worktree, "example.ex"),
      Enum.map_join(1..12, "", &if(&1 in 3..5, do: "changed #{&1}\n", else: "line #{&1}\n"))
    )

    git!(worktree, ["commit", "-am", "the change"])
    head = worktree |> git!(["rev-parse", "HEAD"]) |> String.trim()

    {:ok, _finding} =
      Pipeline.save_finding(task, Map.put(%{code | file: "example.ex", line: 3, end_line: 5}, :key, "range"))

    {:ok, _unchanged} =
      Pipeline.save_finding(task, Map.put(%{code | file: "example.ex", line: 10, end_line: 11}, :key, "unchanged"))

    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
    view |> element("#finding-range") |> render_click()

    assert [{"start", "+ changed3"}, {"middle", "+ changed4"}, {"end", "+ changed5"}] =
             view
             |> render()
             |> Floki.parse_document!()
             |> Floki.find("[data-qa=finding_diff] [data-bracket]")
             |> Enum.map(fn row ->
               {row |> Floki.attribute("data-bracket") |> hd(),
                row |> Floki.text() |> String.split() |> Enum.take(-2) |> Enum.join(" ")}
             end)

    refute has_element?(view, "[data-qa=finding_diff] [data-qa=finding_code_unchanged_chip]")

    # Lines the branch did not change are those lines, never the file's change in their place.
    view |> element("#finding-unchanged") |> render_click()

    assert has_element?(view, "[data-qa=finding_diff] [data-qa=finding_code_unchanged_chip]")
    assert has_element?(view, "[data-qa=finding_code_unchanged]", "on #{String.slice(head, 0, 7)}")
    assert has_element?(view, "[data-qa=finding_diff] [data-bracket=start]", "line 10")
    assert has_element?(view, "[data-qa=finding_diff] [data-bracket=end]", "line 11")
    refute has_element?(view, "[data-qa=finding_diff] [data-qa=diff_line_row]", "changed")
  end

  test "a Where in a file the branch deletes keeps its box, saying so, with Open in Diff", %{
    conn: conn,
    task: %{worktree_path: worktree} = task,
    code: code
  } do
    File.write!(Path.join(worktree, "gone.ex"), Enum.map_join(1..12, "", &"line #{&1}\n"))
    git!(worktree, ["add", "."])
    git!(worktree, ["commit", "-m", "before"])
    git!(worktree, ["update-ref", "refs/remotes/origin/main", "HEAD"])
    git!(worktree, ["rm", "gone.ex"])
    git!(worktree, ["commit", "-m", "the deletion"])

    {:ok, _finding} =
      Pipeline.save_finding(task, Map.put(%{code | file: "gone.ex", line: 3, end_line: 5}, :key, "deleted"))

    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
    view |> element("#finding-deleted") |> render_click()

    assert has_element?(view, "[data-qa=finding_diff] [data-qa=finding_code_missing]", "The branch deletes this file.")
    assert has_element?(view, "[data-qa=finding_diff] [data-qa=diff_stat]", "12")
    assert has_element?(view, "[data-qa=finding_open_in_diff][phx-value-file='gone.ex']")
    refute has_element?(view, "[data-qa=finding_diff] [data-qa=diff_hunk]")
  end

  test "after a fix save each card reads covered or left, and before any fix neither", %{
    conn: conn,
    task: task,
    code: code
  } do
    [handler, action] = code.places
    places = [handler, action, %{screen: "Engineer tab, Diff toolbar", label: "Send button"}]
    {:ok, finding} = Pipeline.save_finding(task, Map.merge(code, %{key: "view-only-send", places: places}))
    {:ok, _pass} = Pipeline.save_review(task)
    {:ok, _ruled} = Pipeline.decide_finding(system_scope(), finding, :fix)

    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
    refute has_element?(view, "[data-qa=finding_place_fix]")

    {:ok, _fixed} =
      Pipeline.save_finding(task, %{
        key: "view-only-send",
        status: "fixed",
        covered: [1, 3],
        left: [%{place: 2, reason: "Already checked there."}],
        test: %{file: "test/a_test.exs", name: "refuses a view-only member"}
      })

    send(view.pid, {:output_saved, task.id})
    # The page hands the reload to the stage as an update of its own, which lands after this render.
    _settled = render(view)

    assert has_element?(view, "#finding-place-1 [data-qa=finding_place_fix]", "Covered by fix round 1")
    assert has_element?(view, "#finding-place-2 [data-qa=finding_place_fix]", "Left by fix round 1:")
    assert has_element?(view, "#finding-place-2 [data-qa=finding_place_fix]", "Already checked there.")
    assert has_element?(view, "#finding-place-3 [data-qa=finding_place_fix]", "Covered by fix round 1")
  end

  test "switching findings reads each one's code once, until a commit moves the branch", %{
    conn: conn,
    task: %{worktree_path: worktree} = task,
    code: code
  } do
    {:ok, _first} = Pipeline.save_finding(task, Map.put(code, :key, "first"))
    {:ok, _second} = Pipeline.save_finding(task, Map.put(%{code | line: 1, end_line: nil}, :key, "second"))

    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    # The page opened on one of the two, so only the other is read.
    expect(Rail.Git, :load_diff_hunks, fn scope, task, ranges ->
      call_original(Rail.Git, :load_diff_hunks, [scope, task, ranges])
    end)

    view |> element("#finding-second") |> render_click()
    view |> element("#finding-first") |> render_click()
    view |> element("#finding-second") |> render_click()
    verify!()

    git!(worktree, ["commit", "--allow-empty", "-m", "moved on"])

    expect(Rail.Git, :load_diff_hunks, fn scope, task, ranges ->
      call_original(Rail.Git, :load_diff_hunks, [scope, task, ranges])
    end)

    view |> element("#finding-first") |> render_click()
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

  test "a task that has moved on from Review offers no fix round", %{conn: conn, task: task, code: code} do
    {:ok, _finding} = Pipeline.save_finding(task, Map.put(code, :key, "view-only-send"))
    {:ok, _pass} = Pipeline.save_review(task)
    {:ok, _merged} = Pipeline.update_task(task, %{stage: :merged})

    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

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

      assert_patch(view, ~p"/tasks/#{task.id}?item=diff")
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

    # The fix commit added b.ex, and round 1 read it, so the Where in b.ex opens on that commit.
    test "every place's code shows in its card, and each card's Open in Diff puts its file in front", %{
      conn: conn,
      task: task,
      code: code
    } do
      places = [
        %{file: "b.ex", line: 1, label: "the module"},
        %{file: "a.ex", line: 1, end_line: 2, label: "the other module"},
        %{file: "b.ex", line: 2},
        %{screen: "Engineer tab", label: "Send button", steps: ["Open the tab", "Click Send"]}
      ]

      finding = %{code | file: "b.ex", line: 1, end_line: nil, places: places}
      {:ok, _finding} = Pipeline.save_finding(task, Map.put(finding, :key, "four-places"))

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      refute has_element?(view, "[data-qa=finding_diff]")
      assert has_element?(view, "#finding-place-1 [data-qa=finding_place_where]")
      assert has_element?(view, "#finding-place-1 [data-bracket=only]", "defmodule B do")
      assert has_element?(view, "#finding-place-2 [data-bracket=start]", "defmodule A do")
      assert has_element?(view, "#finding-place-2 [data-bracket=end]", "end")
      assert has_element?(view, "#finding-place-3 [data-bracket=only]", "end")
      assert has_element?(view, "#finding-place-4 ol li", "Click Send")
      refute has_element?(view, "#finding-place-4 [data-qa=finding_code]")

      view |> element("#finding-place-2-open-in-diff") |> render_click()

      assert has_element?(view, "#review-pane[data-item=diff] #diff-commit-picker", "Whole branch")
      assert has_element?(view, "#diff-scroller[data-scroll-to='a.ex']")

      view |> element("#review-item-findings") |> render_click()
      view |> element("#finding-place-1-open-in-diff") |> render_click()

      assert has_element?(view, "#diff-commit-picker", "Fix round 1")
      assert has_element?(view, "[data-qa='diff_file_section'][data-path='b.ex']")
      refute has_element?(view, "[data-qa='diff_file_section'][data-path='a.ex']")
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
      assert_patch(view, ~p"/tasks/#{task.id}?item=findings")
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

      # The finished review moved the task on to Finalize, which still takes comments.
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
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
      assert has_element?(view, "#review-item-findings[title='Findings: Fix round 2 · writing the fix plan']")
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

    # A fix plan made of comments alone has nothing ruled Fix, so its round fixes no finding.
    test "a fix round with no Fix finding says what was sent is being worked on", %{
      conn: conn,
      task: task,
      engineer_run: engineer_run
    } do
      {:ok, %{round: 2}} = Pipeline.save_review(task)
      {:ok, _fixing} = Pipeline.update_task(task, %{stage: :engineer})
      {:ok, _working} = Pipeline.update_run(engineer_run, %{status: :running})

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}?item=findings")

      assert has_element?(view, "#review-status[data-phase=fixing]", "Nothing is ruled Fix")
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
      expect(Pipeline, :record_demo, fn _scope, _task -> {:ok, run} end)
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

  describe "the fix plan" do
    setup %{task: task, run: run, user: user, code: code, screen: screen} do
      {:ok, view_only} = Pipeline.save_finding(task, Map.put(code, :key, "view-only-send"))
      {:ok, twice} = Pipeline.save_finding(task, Map.put(screen, :key, "send-twice"))
      {:ok, _pass} = Pipeline.save_review(task)
      {:ok, _ruled} = Pipeline.decide_finding(system_scope(), view_only, :fix)
      {:ok, _ruled} = Pipeline.decide_finding(system_scope(), twice, :fix)
      diff = %{path: "lib/a.ex", line_kind: :added, line: 3, line_text: "x = 1", filter: :branch}
      {:ok, _comment} = Pipeline.create_diff_comment(user_scope(user: user), task, Map.put(diff, :body, "Name it."))

      expect(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)
      {:ok, _started} = Pipeline.start_fix_round(user_scope(user: user), run)

      plan =
        "Two fixes.\n\n### What changes\n\n#### `view-only-send`\n\nCheck the role.\n\n#### `send-twice`\n\n" <>
          "Disable Send.\n\n#### Comment 1\n\nNamed.\n\n### File-level changes\n\n" <>
          "- `lib/rail/send.ex`: checks the role. For `view-only-send`.\n" <>
          "- `lib/rail_web/tray.ex`: disables Send. For `send-twice` and comment 1."

      %{plan: plan, diff: diff, view_only: view_only, twice: twice}
    end

    test "while the lead writes it, Fix plan runs under Findings with no Approve anywhere", %{conn: conn, task: task} do
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "#review-item-fix-plan[title='Fix plan: Writing the plan'] [data-qa=review_item_running]")
      assert has_element?(view, "#review-status", "Fix round 1 · Review lead writing the fix plan")
      refute has_element?(view, "#approve-fix-plan")

      view |> element("#review-item-fix-plan") |> render_click()
      assert has_element?(view, "#fix-plan-empty", "Writing the fix plan")
      assert has_element?(view, "#fix-plan-empty", "On the 2 findings ruled Fix and comment 1.")
    end

    test "a turn that stopped before a plan was saved leaves nothing to approve", %{conn: conn, task: task, run: run} do
      {:ok, _stopped} = run |> Repo.reload!() |> Pipeline.update_run(%{status: :finished})
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}?item=fix_plan")

      assert has_element?(view, "#review-item-fix-plan[title='Fix plan: No plan'] [data-qa=review_item_stopped]")
      assert has_element?(view, "#fix-plan-empty", "No fix plan")
      refute has_element?(view, "#approve-fix-plan")
    end

    test "a waiting plan reads under Findings, opens full pane with its items and files, and Approve sits in the header",
         %{conn: conn, task: task, run: run, plan: plan} do
      {:ok, _saved} = Pipeline.save_fix_plan(task, %{"plan" => plan})
      {:ok, _done} = run |> Repo.reload!() |> Pipeline.update_run(%{status: :finished, stage_outcome: :done})
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      assert has_element?(
               view,
               "#review-item-fix-plan[title='Fix plan: Waiting on your approval'] [data-qa=review_item_waiting]"
             )

      assert has_element?(view, "#review-status[data-phase=waiting]", "Fix round 1 · Fix plan waiting on your approval")
      assert has_element?(view, "#decide-fix-view-only-send")
      assert has_element?(view, "#decide-skip-view-only-send")
      assert has_element?(view, "#approve-fix-plan")
      assert has_element?(view, "#review-send-tray-hint", "saves a revised fix plan in place of this one")
      refute has_element?(view, "#finish-review")

      view |> element("#review-status-open-fix-plan") |> render_click()
      assert has_element?(view, "#review-pane[data-item=fix_plan] #fix-plan-item-view-only-send")
      assert has_element?(view, "#fix-plan-item-send-twice")
      assert has_element?(view, "#fix-plan-item-comment-1", "Name it.")
      assert has_element?(view, "#plan-file-2", "lib/rail_web/tray.ex")
      assert_patch(view, ~p"/tasks/#{task.id}?item=fix_plan")
    end

    test "the fix_plan item in the URL opens the plan on load", %{conn: conn, task: task, run: run, plan: plan} do
      {:ok, _saved} = Pipeline.save_fix_plan(task, %{"plan" => plan})
      {:ok, _done} = run |> Repo.reload!() |> Pipeline.update_run(%{status: :finished, stage_outcome: :done})
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}?item=fix_plan")

      assert has_element?(view, "#review-item-fix-plan[aria-current=true]")
      assert has_element?(view, "#fix-plan-sheet")
    end

    test "ruling a Fix finding Don't fix withdraws Approve and marks the change everywhere, and ruling it back undoes it",
         %{conn: conn, task: task, run: run, plan: plan, view_only: view_only, twice: twice} do
      {:ok, _saved} = Pipeline.save_fix_plan(task, %{"plan" => plan})
      {:ok, _done} = run |> Repo.reload!() |> Pipeline.update_run(%{status: :finished, stage_outcome: :done})
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      view |> element("#finding-view-only-send") |> render_click()
      view |> element("#decide-skip-view-only-send") |> render_click()
      _settled = render(view)

      refute has_element?(view, "#approve-fix-plan")
      assert has_element?(view, "#review-item-fix-plan[title='Fix plan: Out of date']")
      assert has_element?(view, "#review-status[data-phase=outdated]", "Fix round 1 · Fix plan out of date")
      assert has_element?(view, "#finding-view-only-send", "Don't fix · changed since the plan")
      assert has_element?(view, "#finding-ruling-changed", "Ruling changed since the fix plan · was Fix")
      assert has_element?(view, "#review-tray-ruling-view-only-send", "Don't fix, was Fix")
      assert has_element?(view, "#review-send-tray-hint", "The fix plan is out of date. Send asks the lead to revise it.")

      view |> element("#review-item-fix-plan") |> render_click()
      assert has_element?(view, "#fix-plan-outdated code", "view-only-send")
      assert has_element?(view, "#fix-plan-outdated", "view-only-send changed from Fix to Don't fix after")
      refute has_element?(view, "#fix-plan-outdated", "`")
      assert has_element?(view, "#fix-plan-item-view-only-send [data-qa=fix_plan_item_changed]", "Now Don't fix")

      view |> element("#review-item-findings") |> render_click()
      Process.sleep(400)
      view |> element("#decide-fix-view-only-send") |> render_click()
      _settled = render(view)

      assert has_element?(view, "#approve-fix-plan")
      refute has_element?(view, "#review-tray-ruling-view-only-send")
      refute has_element?(view, "#finding-ruling-changed")
      assert has_element?(view, "#review-item-fix-plan[title='Fix plan: Waiting on your approval']")

      {:ok, _ruled} = Pipeline.decide_finding(system_scope(), view_only, :skip)
      {:ok, _ruled} = Pipeline.decide_finding(system_scope(), twice, :skip)
      view |> element("#review-item-fix-plan") |> render_click()

      assert has_element?(
               view,
               "#fix-plan-outdated",
               "view-only-send changed from Fix to Don't fix and send-twice changed from Fix to Don't fix after"
             )
    end

    test "a Send while the plan waits leaves the plan revising on what it carried, with no Approve", %{
      conn: conn,
      task: task,
      run: run,
      user: user,
      plan: plan,
      diff: diff
    } do
      {:ok, _saved} = Pipeline.save_fix_plan(task, %{"plan" => plan})
      {:ok, _done} = run |> Repo.reload!() |> Pipeline.update_run(%{status: :finished, stage_outcome: :done})
      {:ok, _comment} = Pipeline.create_diff_comment(user_scope(user: user), task, Map.put(diff, :body, "And this."))
      {:ok, _comment} = Pipeline.create_diff_comment(user_scope(user: user), task, Map.put(diff, :body, "And that."))
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}?item=fix_plan")

      expect(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)
      view |> element("#send-review-tray", "Send 2") |> render_click()
      _settled = render(view)

      refute has_element?(view, "#approve-fix-plan")
      assert has_element?(view, "#review-item-fix-plan[title='Fix plan: Revising']")
      assert has_element?(view, "#fix-plan-revising", "Revising on comments 2 and 3.")
      assert has_element?(view, "#fix-plan-sheet")

      {:ok, _stopped} = run |> Repo.reload!() |> Pipeline.update_run(%{status: :finished})
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}?item=fix_plan")
      assert has_element?(view, "#fix-plan-revising", "The lead stopped before it saved the revised plan")
      assert has_element?(view, "#review-item-fix-plan[title='Fix plan: Revision stopped']")
    end

    test "a plan revised on a dropped finding and a new comment still lays out what it covers, not ticked as the round",
         %{conn: conn, task: task, run: run, user: user, plan: plan, diff: diff, view_only: view_only} do
      {:ok, _saved} = Pipeline.save_fix_plan(task, %{"plan" => plan})
      {:ok, _done} = run |> Repo.reload!() |> Pipeline.update_run(%{status: :finished, stage_outcome: :done})
      {:ok, _ruled} = Pipeline.decide_finding(system_scope(), view_only, :skip)
      {:ok, _comment} = Pipeline.create_diff_comment(user_scope(user: user), task, Map.put(diff, :body, "And this."))
      expect(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)
      {:ok, _sent} = Pipeline.start_fix_round(user_scope(user: user), run)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}?item=fix_plan")

      assert has_element?(view, "#fix-plan-item-view-only-send", "File 1")
      refute has_element?(view, "#fix-plan-item-comment-2")
      assert has_element?(view, "#plan-summary", "Both Fix findings and comment 1 covered, before the last Send")
    end

    test "Approve makes the plan the next round and starts the engineer on it, on a clean conversation", %{
      conn: conn,
      task: task,
      run: run,
      plan: plan
    } do
      {:ok, _saved} = Pipeline.save_fix_plan(task, %{"plan" => plan})
      {:ok, _done} = run |> Repo.reload!() |> Pipeline.update_run(%{status: :finished, stage_outcome: :done})
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      view |> element("#approve-fix-plan") |> render_click()
      refute has_element?(view, "#approve-fix-plan")
      assert %Task{stage: :engineer} = Repo.reload!(task)
      assert [%Round{number: 1, plan: ^plan, approved_at: %DateTime{}}] = Pipeline.list_rounds(task)

      # The engineer is started by the job committed with the round, which the page hears when it has.
      expect(Tools, :start_os_process, fn spawned, ["-p", prompt | _rest] = argv ->
        assert prompt =~ plan
        refute "--resume" in argv
        {:ok, %OsProcess{run: spawned}}
      end)

      [%Oban.Job{args: args}] = all_enqueued(worker: StartEngineer)
      assert :ok = perform_job(StartEngineer, args)
    end

    test "Approve on a replaced plan is refused with the time it was replaced, and nothing starts", %{
      conn: conn,
      task: task,
      run: run,
      plan: plan
    } do
      {:ok, _saved} = Pipeline.save_fix_plan(task, %{"plan" => plan})
      {:ok, _done} = run |> Repo.reload!() |> Pipeline.update_run(%{status: :finished, stage_outcome: :done})
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      {:ok, _replaced} = Pipeline.save_fix_plan(task, %{"plan" => plan <> " Again."})

      reject(Tools, :start_os_process, 2)
      view |> element("#approve-fix-plan") |> render_click(%{"version" => "1"})

      assert has_element?(view, "#review-error", "That fix plan was replaced at")
      assert has_element?(view, "#review-error", "Nothing started. Read the plan on screen, then approve it.")
      assert %{status: :finished} = Repo.reload!(run)
    end

    test "every other refusal of an Approve says why in the header", %{conn: conn, task: task, run: run, plan: plan} do
      {:ok, _saved} = Pipeline.save_fix_plan(task, %{"plan" => plan})
      {:ok, _done} = run |> Repo.reload!() |> Pipeline.update_run(%{status: :finished, stage_outcome: :done})
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      for {reason, said} <- [
            {{:fix_plan_not_waiting, :outdated}, "A ruling changed since that plan was saved. Nothing started."},
            {{:fix_plan_not_waiting, :approved}, "That fix plan is already approved."},
            {{:fix_plan_not_waiting, :revising}, "The lead is revising that fix plan. Nothing started."},
            {:no_fix_plan, "There is no fix plan to approve."},
            {:stage_running, "Something is still running on this task."}
          ] do
        expect(Pipeline, :approve_fix_plan, fn _scope, _run, 1 -> {:error, reason} end)
        view |> element("#approve-fix-plan") |> render_click()
        assert has_element?(view, "#review-error", said)
      end
    end

    test "a second tab updates when a plan is saved, when a ruling changes and when the plan is approved", %{
      conn: conn,
      task: task,
      run: run,
      plan: plan,
      view_only: view_only
    } do
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}?item=fix_plan")
      {:ok, other, _html} = live(conn, ~p"/tasks/#{task.id}?item=fix_plan")

      {:ok, _saved} = Pipeline.save_fix_plan(task, %{"plan" => plan})
      _settled = render(other)
      assert has_element?(other, "#fix-plan-sheet")

      # The turn's end is what the page hears next.
      {:ok, _done} = run |> Repo.reload!() |> Pipeline.update_run(%{status: :finished, stage_outcome: :done})
      Phoenix.PubSub.broadcast(Rail.PubSub, "pipeline", {:pipeline_changed, task.id})
      _settled = render(other)
      assert has_element?(other, "#approve-fix-plan")

      {:ok, _ruled} = Pipeline.decide_finding(system_scope(), view_only, :skip)
      _settled = render(other)
      refute has_element?(other, "#approve-fix-plan")

      {:ok, _ruled} = Pipeline.decide_finding(system_scope(), view_only, :fix)
      _settled = render(view)
      view |> element("#approve-fix-plan") |> render_click()
      _settled = render(other)
      refute has_element?(other, "#approve-fix-plan")
      assert [%Oban.Job{}] = all_enqueued(worker: StartEngineer)
    end
  end
end
