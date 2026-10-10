defmodule RailWeb.LearningsLiveTest do
  use RailWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Rail.Learnings
  alias Rail.Learnings.Schemas.CuratorPass
  alias Rail.Learnings.Schemas.Learning
  alias Rail.Learnings.Schemas.LearningProposal
  alias Rail.Learnings.Schemas.Observation
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.DiffComment
  alias Rail.Pipeline.Schemas.PlanComment
  alias Rail.Pipeline.Schemas.PlanCommentCapture
  alias Rail.Repo
  alias Rail.Users

  setup %{conn: conn, project: project} do
    id = System.unique_integer([:positive])

    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "llv-1-#{id}",
        login: "dana-#{id}",
        name: "Dana Okafor",
        email: "dana-#{id}@llv.example"
      })

    {:ok, user} = Users.update_user(system_scope(), user, %{project_ids: [project.id]})
    conn = conn |> log_in_user(user) |> Plug.Conn.put_session(:selected_project_id, project.id)

    %{conn: conn, user: user}
  end

  test "the four segments are counted and the queue opens on what is waiting", %{conn: conn, project: project} do
    rule = learning(project, %{rule: "Use the factory", kind: :convention})
    learning(project, %{rule: "Fresh correction", kind: :convention}, status: :provisional)
    draft = learning(project, %{rule: "Tests build rows with builders", kind: :convention}, status: :proposed)

    Repo.insert!(%LearningProposal{
      project_id: project.id,
      action: :merge,
      learning_id: draft.id,
      target_ids: [rule.id],
      title: "Merge the fixture rules",
      summary: "RAIL-35, RAIL-41"
    })

    {:ok, view, html} = live(conn, ~p"/learnings")

    assert html =~ "Learnings"
    assert has_element?(view, "#learnings-segment-review[aria-pressed=true]", "To review")
    assert has_element?(view, "#learnings-segment-review span.text-amber-600", "1")
    assert has_element?(view, "#learnings-segment-active", "Active")
    assert has_element?(view, "#learnings-segment-provisional", "1")
    assert has_element?(view, "#learnings-segment-retired", "0")
    assert has_element?(view, "#learnings-match-line", "1 to review, oldest first")
    assert has_element?(view, "[data-qa=proposal-card]", "Merge 1")
    assert has_element?(view, "[data-qa=proposal-card]", "RAIL-35, RAIL-41")
    assert has_element?(view, "#proposal-title", "Merge the fixture rules")
    assert has_element?(view, "[data-qa=proposal-removed]", "Use the factory")
    assert has_element?(view, "[data-qa=proposal-draft]", "Tests build rows with builders")

    view |> element("#learnings-segment-active") |> render_click()
    assert_patch(view, ~p"/learnings?status=active")
    assert has_element?(view, "#learning-card-#{rule.id}", "Use the factory")
    assert has_element?(view, "#learnings-match-line", "1 active, newest first")
    assert has_element?(view, "#learning-rule", "Use the factory")
  end

  test "each rule and proposal is at its own URL, and an override opens the rule it flags", %{
    conn: conn,
    project: project
  } do
    rule =
      learning(project, %{
        rule: "Don't flag a missing @doc",
        why: "Components document themselves",
        kind: :calibration,
        roles: [:review],
        path_glob: "lib/rail_web/components/**"
      })

    override = Repo.insert!(%LearningProposal{project_id: project.id, action: :override, learning_id: rule.id})
    task = learnings_task(project, "OWN-1", :review)

    {:ok, _doc} =
      Pipeline.save_finding(task, %{
        key: "doc",
        kind: :code,
        raised_by: :code_reviewer,
        title: "Missing @doc",
        problem: "A task with no worktree crashes the page.",
        file: "lib/a.ex",
        line: 3,
        fix: "Guard the nil in the action.",
        why: "It crashes.",
        rule: "Every caller handles a missing worktree.",
        severity: :nit,
        recommendation: :skip,
        checklist_rule: rule.id,
        places: [%{file: "lib/a.ex", line: 3, label: "handle/1"}],
        evidence: [%{name: "The clause", kind: :code, file: "lib/a.ex", line: 3}]
      })

    {:ok, view, _html} = live(conn, ~p"/learnings/#{rule.id}")
    assert has_element?(view, "#learnings-segment-active[aria-pressed=true]")
    assert has_element?(view, "#learning-suppressed", "1 across 1 task")
    assert has_element?(view, "#learning-detail [data-qa=learning-status]", "Flagged")
    assert has_element?(view, "#learning-detail", "lib/rail_web/components/**")
    assert has_element?(view, "#learning-why", "Components document themselves")
    assert has_element?(view, "#learning-override-banner", "Flagged: a person decided Fix")

    {:error, {:live_redirect, %{to: to}}} = live(conn, ~p"/learnings/proposals/#{override.id}")
    {:ok, view, _html} = live(conn, to)
    assert has_element?(view, "#learning-rule", "Don't flag a missing @doc")

    view |> element("#keep-rule-button") |> render_click()
    assert %LearningProposal{status: :rejected} = Repo.reload!(override)
    refute has_element?(view, "#learning-override-banner")
  end

  test "searching ranks rules nearest first, and says so when it cannot search", %{conn: conn, project: project} do
    stub_vertex(%{"doc on components" => vector([1.0])})
    near = learning(project, %{rule: "Don't flag a missing @doc", kind: :calibration}, embedding: [0.9, 0.1])
    far_rule = learning(project, %{rule: "Copy says task", kind: :product}, embedding: [0.1, 0.9])

    {:ok, view, _html} = live(conn, ~p"/learnings")
    view |> form("#learnings-search-form", %{q: "doc on components"}) |> render_change()

    assert_patch(view, ~p"/learnings?q=doc+on+components&status=active")
    assert has_element?(view, "#learnings-match-line", "2 matches, best first")
    html = view |> element("#learnings-list") |> render()
    assert [_before, after_near] = String.split(html, "learning-card-#{near.id}")
    assert after_near =~ "learning-card-#{far_rule.id}"

    assert_received {:embedded, "doc on components", "RETRIEVAL_QUERY"}
    send(view.pid, {:learnings_changed, project.id})
    assert has_element?(view, "#learnings-match-line", "2 matches, best first")
    refute_received {:embedded, _text, _task_type}

    view |> form("#learnings-search-form", %{q: "components"}) |> render_change()
    assert_received {:embedded, "components", "RETRIEVAL_QUERY"}

    {:ok, _view, _html} = live(conn, ~p"/learnings?status=review&q=components")
    refute_received {:embedded, _text, _task_type}

    stub_vertex_down()
    {:ok, view, _html} = live(conn, ~p"/learnings?status=active&q=anything")
    assert has_element?(view, "#learnings-match-line", "Search is unavailable right now")
    refute has_element?(view, "[data-qa=learning-card]")
  end

  test "the kind and role menus and the two chips filter through the URL", %{conn: conn, project: project} do
    week = learning(project, %{rule: "Recent and auto", kind: :convention, roles: [:review]}, auto: true)
    old = learning(project, %{rule: "Old decision", kind: :decision}, activated_at: ~U[2026-01-01 00:00:00Z])

    {:ok, view, _html} = live(conn, ~p"/learnings?status=active")

    view |> element("#learnings-kind-menu") |> render_click()
    assert has_element?(view, "#learnings-kind-options")
    view |> element("#learnings-kind-decision") |> render_click()
    assert_patch(view, ~p"/learnings?status=active&kind=decision")
    assert has_element?(view, "#learning-card-#{old.id}")
    refute has_element?(view, "#learning-card-#{week.id}")

    view |> element("#learnings-kind-menu") |> render_click()
    view |> element("#learnings-kind-any") |> render_click()
    view |> element("#learnings-role-menu") |> render_click()
    view |> element("#learnings-role-menu") |> render_click()
    refute has_element?(view, "#learnings-role-options")
    view |> element("#learnings-role-menu") |> render_click()
    render_click(view, "close_menu", %{})
    refute has_element?(view, "#learnings-role-options")
    view |> element("#learnings-role-menu") |> render_click()
    view |> element("#learnings-role-engineer") |> render_click()
    assert_patch(view, ~p"/learnings?status=active&role=engineer")
    assert has_element?(view, "#learning-card-#{old.id}")
    refute has_element?(view, "#learning-card-#{week.id}")

    {:ok, view, _html} = live(conn, ~p"/learnings?status=active")
    view |> element("#learnings-auto") |> render_click()
    assert_patch(view, ~p"/learnings?status=active&auto=true")
    assert has_element?(view, "#learnings-auto[aria-pressed=true]")
    refute has_element?(view, "#learning-card-#{old.id}")

    view |> element("#learnings-auto") |> render_click()
    view |> element("#learnings-week") |> render_click()
    assert_patch(view, ~p"/learnings?status=active&week=true")
    assert has_element?(view, "#learning-card-#{week.id}")
    refute has_element?(view, "#learning-card-#{old.id}")
  end

  test "the three empty states", %{conn: conn, project: project} do
    {:ok, view, _html} = live(conn, ~p"/learnings")
    assert has_element?(view, "#learnings-empty", "Nothing to review")
    assert has_element?(view, "#learnings-empty", "The curator runs at 06:00.")

    {:ok, view, _html} = live(conn, ~p"/learnings?status=active")
    assert has_element?(view, "#learnings-empty", "No rules in #{project.name} yet")

    stub_vertex()
    learning(project, %{rule: "Not embedded yet", kind: :convention})
    {:ok, view, _html} = live(conn, ~p"/learnings?status=active&q=storybook+snapshot")
    assert has_element?(view, "#learnings-empty", "No rules match “storybook snapshot”")

    {:ok, view, _html} = live(conn, ~p"/learnings?status=retired")
    assert has_element?(view, "#learnings-empty", "No rules match these filters")
  end

  test "approving a proposal applies it and opens the next, and a second approval is refused", %{
    conn: conn,
    project: project
  } do
    draft = learning(project, %{rule: "Draft", kind: :convention}, status: :proposed)
    proposal = Repo.insert!(%LearningProposal{project_id: project.id, action: :add, learning_id: draft.id})

    {:ok, view, _html} = live(conn, ~p"/learnings/proposals/#{proposal.id}")
    {:ok, _approved} = Learnings.approve_learning_proposal(system_scope(), proposal)
    view |> element("#approve-proposal-button") |> render_click()
    assert has_element?(view, "#learnings-error", "Someone already decided this proposal.")

    other = learning(project, %{rule: "Another draft", kind: :convention}, status: :proposed)
    next = Repo.insert!(%LearningProposal{project_id: project.id, action: :add, learning_id: other.id})
    {:ok, view, _html} = live(conn, ~p"/learnings/proposals/#{next.id}")
    view |> element("#approve-proposal-button") |> render_click()
    assert_patch(view, ~p"/learnings?status=review")
    assert %Learning{status: :active} = Repo.reload!(other)
    assert has_element?(view, "#learnings-empty", "Nothing to review")
  end

  test "a second click on Approve after the first decided names the proposal, so it never decides the next", %{
    conn: conn,
    project: project
  } do
    [first, second] =
      for n <- 1..2 do
        draft = learning(project, %{rule: "Draft #{n}", kind: :convention}, status: :proposed)
        Repo.insert!(%LearningProposal{project_id: project.id, action: :add, learning_id: draft.id})
      end

    {:ok, view, _html} = live(conn, ~p"/learnings/proposals/#{first.id}")
    view |> element("#approve-proposal-button") |> render_click()
    render_click(view, "approve_proposal", %{"id" => first.id})

    assert has_element?(view, "#learnings-error", "Someone already decided this proposal.")
    assert %LearningProposal{status: :approved} = Repo.reload!(first)
    assert %LearningProposal{status: :pending} = Repo.reload!(second)

    {:ok, view, _html} = live(conn, ~p"/learnings/proposals/#{second.id}")
    render_click(view, "reject_proposal", %{"id" => "lpr_none"})
    assert has_element?(view, "#learnings-error", "Someone already decided this proposal.")
  end

  # The second click of a double click lands on the proposal the queue moved to, which nobody has read.
  test "a double click on Approve or Reject decides only the proposal that was open", %{conn: conn, project: project} do
    [first, second, third] =
      for n <- 1..3 do
        draft = learning(project, %{rule: "Draft #{n}", kind: :convention}, status: :proposed)
        Repo.insert!(%LearningProposal{project_id: project.id, action: :add, learning_id: draft.id})
      end

    {:ok, view, _html} = live(conn, ~p"/learnings/proposals/#{first.id}")
    view |> element("#approve-proposal-button") |> render_click()
    assert has_element?(view, "#proposal-detail", "Draft 2")
    view |> element("#approve-proposal-button") |> render_click()

    assert %LearningProposal{status: :approved} = Repo.reload!(first)
    assert %LearningProposal{status: :pending} = Repo.reload!(second)

    Process.sleep(400)
    view |> element("#reject-proposal-button") |> render_click()
    view |> element("#reject-proposal-button") |> render_click()

    assert %LearningProposal{status: :rejected} = Repo.reload!(second)
    assert %LearningProposal{status: :pending} = Repo.reload!(third)
    assert has_element?(view, "#proposal-detail", "Draft 3")
  end

  test "Keep rule clicked twice decides its override once and leaves the page working", %{conn: conn, project: project} do
    rule = learning(project, %{rule: "Don't flag a missing @doc", kind: :calibration})
    override = Repo.insert!(%LearningProposal{project_id: project.id, action: :override, learning_id: rule.id})

    {:ok, view, _html} = live(conn, ~p"/learnings/#{rule.id}")
    view |> element("#keep-rule-button") |> render_click()
    render_click(view, "keep_rule", %{"id" => override.id})
    render_click(view, "keep_rule", %{})

    assert %LearningProposal{status: :rejected} = Repo.reload!(override)
    assert has_element?(view, "#learning-rule", "Don't flag a missing @doc")
    refute has_element?(view, "#keep-rule-button")
  end

  test "rejecting a proposal leaves its rule as it was", %{conn: conn, project: project} do
    gone = learning(project, %{rule: "Gone", kind: :environment})
    proposal = Repo.insert!(%LearningProposal{project_id: project.id, action: :retire, learning_id: gone.id})

    {:ok, view, _html} = live(conn, ~p"/learnings/proposals/#{proposal.id}")
    view |> element("#reject-proposal-button") |> render_click()

    assert_patch(view, ~p"/learnings?status=review")
    assert %LearningProposal{status: :rejected} = Repo.reload!(proposal)
    assert %Learning{status: :active} = Repo.reload!(gone)
  end

  test "Add rule writes an active rule and opens it", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/learnings")

    view |> element("#add-learning-button") |> render_click()
    assert has_element?(view, "#learning-form-modal")
    refute has_element?(view, "#learning-project")

    view |> form("#learning-form", learning: %{rule: "", kind: "convention"}) |> render_submit()
    assert has_element?(view, "#learning-form-modal", "can't be blank")

    view
    |> form("#learning-form",
      learning: %{
        rule: "Use the factory",
        why: "Rows stay valid",
        kind: "convention",
        roles: ["engineer"],
        path_glob: "test/**",
        pinned: "true"
      }
    )
    |> render_change()

    view
    |> form("#learning-form",
      learning: %{
        rule: "Use the factory",
        why: "Rows stay valid",
        kind: "convention",
        roles: ["engineer"],
        path_glob: "test/**",
        pinned: "true"
      }
    )
    |> render_submit()

    assert %Learning{id: id, status: :active, roles: [:engineer], pinned: true, path_glob: "test/**"} =
             Repo.get_by!(Learning, rule: "Use the factory")

    assert_patch(view, ~p"/learnings/#{id}?status=active")
    refute has_element?(view, "#learning-form-modal")
    assert has_element?(view, "#learning-rule", "Use the factory")
  end

  test "Edit changes a rule or a proposal's draft, and Escape or Cancel closes the form", %{conn: conn, project: project} do
    rule = learning(project, %{rule: "Use the factory", kind: :convention})

    {:ok, view, _html} = live(conn, ~p"/learnings/#{rule.id}")
    view |> element("#edit-learning-button") |> render_click()
    assert has_element?(view, "#learning-form-modal", "Edit rule")
    render_keydown(view, "close_form", %{"key" => "Escape"})
    refute has_element?(view, "#learning-form-modal")

    view |> element("#edit-learning-button") |> render_click()
    view |> form("#learning-form", learning: %{rule: "Use the factory builders", kind: "convention"}) |> render_submit()
    assert %Learning{rule: "Use the factory builders"} = Repo.reload!(rule)
    assert has_element?(view, "#learning-rule", "Use the factory builders")

    draft = learning(project, %{rule: "Draft", kind: :convention}, status: :proposed)
    proposal = Repo.insert!(%LearningProposal{project_id: project.id, action: :add, learning_id: draft.id})
    {:ok, view, _html} = live(conn, ~p"/learnings/proposals/#{proposal.id}")
    view |> element("#edit-proposal-button") |> render_click()
    assert has_element?(view, "#learning-form-modal", "Edit the proposed rule")
    view |> element("#cancel-learning-button") |> render_click()
    refute has_element?(view, "#learning-form-modal")

    view |> element("#edit-proposal-button") |> render_click()
    view |> form("#learning-form", learning: %{rule: "Edited draft", kind: "convention"}) |> render_submit()
    assert_patch(view, ~p"/learnings/proposals/#{proposal.id}?status=review")
    assert has_element?(view, "[data-qa=proposal-draft]", "Edited draft")
    assert has_element?(view, "#approve-proposal-button")
  end

  test "Retire retires the rule, and its stats show what it suppressed and where it came from", %{
    conn: conn,
    project: project,
    user: user
  } do
    rule = learning(project, %{rule: "Don't flag a missing @doc", kind: :calibration})
    task = learnings_task(project, "LLV-1", :review)

    findings =
      for n <- 1..8,
          do: %{
            key: "doc-#{n}",
            kind: :code,
            raised_by: :code_reviewer,
            title: "Missing @doc #{n}",
            problem: "A task with no worktree crashes the page.",
            file: "lib/c.ex",
            line: n,
            fix: "Guard the nil in the action.",
            why: "It crashes.",
            rule: "Every caller handles a missing worktree.",
            severity: :nit,
            recommendation: :skip,
            checklist_rule: rule.id,
            places: [%{file: "lib/c.ex", line: n, label: "handle/1"}],
            evidence: [%{name: "The clause", kind: :code, file: "lib/c.ex", line: n}]
          }

    [first | _rest] =
      for finding <- findings do
        {:ok, saved} = Pipeline.save_finding(task, finding)

        saved
      end

    second_task = learnings_task(project, "LLV-3", :review)

    for finding <- [%{hd(findings) | key: "elsewhere"}],
        do: {:ok, _saved} = Pipeline.save_finding(second_task, finding)

    {:ok, fixed} = Pipeline.decide_finding(Rail.Scope.for_user(user), first, :fix)
    {:ok, _flagged} = Learnings.record_overrides(task, [fixed])

    {:ok, view, _html} = live(conn, ~p"/learnings/#{rule.id}")
    assert has_element?(view, "#learning-override-banner", "Flagged: Dana Okafor decided Fix on")
    assert has_element?(view, "#learning-override-banner", "LLV-1")
    assert has_element?(view, "#learning-figures", "findings suppressed")
    assert has_element?(view, "#learning-figures", "0 retrievals")
    assert has_element?(view, "#learning-suppressed", "9 across 2 tasks")
    refute has_element?(view, "#suppressed-#{first.id}")
    assert has_element?(view, "#suppressed-more", "3 more")
    assert has_element?(view, "#learning-sources", "Fixed anyway · Dana Okafor")

    view |> element("#suppressed-more") |> render_click()
    refute has_element?(view, "#suppressed-more")
    assert has_element?(view, "#suppressed-#{first.id}", "Fixed anyway")

    view |> element("#retire-learning-button") |> render_click()
    assert %Learning{status: :retired} = Repo.reload!(rule)
    refute has_element?(view, "#retire-learning-button")
  end

  test "under All projects the cards carry project badges, Add rule asks which project, and there is no digest link", %{
    conn: conn,
    project: %{id: project_id} = project
  } do
    rule = learning(project, %{rule: "Use the factory", kind: :convention})
    conn = Plug.Conn.put_session(conn, :selected_project_id, nil)

    {:ok, view, _html} = live(conn, ~p"/learnings?status=active")
    assert has_element?(view, "#learning-card-#{rule.id} [data-qa=project-badge]", "TST")
    refute has_element?(view, "#learnings-digest-link")

    view |> element("#add-learning-button") |> render_click()
    assert has_element?(view, "#learning-project")

    view
    |> form("#learning-form", learning: %{project_id: project_id, rule: "Picked project", kind: "decision"})
    |> render_submit()

    assert %Learning{project_id: ^project_id} = Repo.get_by!(Learning, rule: "Picked project")
  end

  test "a project the person was not granted shows none of its rules or proposals, and takes no new rule", %{conn: conn} do
    {:ok, hidden} =
      Rail.Projects.create_project(system_scope(), %{
        name: "Hidden",
        github_repo: "example/hidden",
        github_installation_id: 1,
        default_branch: "main",
        key: "HID",
        clone_path: "/tmp/repos/hidden"
      })

    rule = learning(hidden, %{rule: "Hidden rule", kind: :convention})
    draft = learning(hidden, %{rule: "Hidden draft", kind: :convention}, status: :proposed)
    proposal = Repo.insert!(%LearningProposal{project_id: hidden.id, action: :add, learning_id: draft.id})
    conn = Plug.Conn.put_session(conn, :selected_project_id, nil)

    {:ok, view, _html} = live(conn, ~p"/learnings?status=active")
    refute has_element?(view, "#learning-card-#{rule.id}")

    {:ok, view, _html} = live(conn, ~p"/learnings?status=review")
    refute has_element?(view, "#learnings-list", "Hidden draft")

    {:ok, view, _html} = live(conn, ~p"/learnings/#{rule.id}")
    refute has_element?(view, "#learning-rule", "Hidden rule")

    {:ok, view, _html} = live(conn, ~p"/learnings/proposals/#{proposal.id}")
    refute has_element?(view, "#proposal-detail")

    view |> element("#add-learning-button") |> render_click()

    view
    |> form("#learning-form", learning: %{rule: "Smuggled", kind: "decision"})
    |> render_submit(%{learning: %{project_id: hidden.id}})

    assert has_element?(view, "#learning-form-modal")
    refute Repo.get_by(Learning, rule: "Smuggled")

    override = Repo.insert!(%LearningProposal{project_id: hidden.id, action: :override, learning_id: rule.id})

    for {event, id} <- [{"approve_proposal", proposal.id}, {"reject_proposal", proposal.id}, {"keep_rule", override.id}] do
      render_click(view, event, %{"id" => id})
    end

    assert %LearningProposal{status: :pending} = Repo.reload!(proposal)
    assert %LearningProposal{status: :pending} = Repo.reload!(override)
  end

  test "the digest link names the learnings channel, not an older triage channel, and opens the latest digest", %{
    conn: conn,
    project: project
  } do
    {:ok, view, html} = live(conn, ~p"/learnings")
    refute has_element?(view, "#learnings-digest-link")
    refute html =~ "06:00 digest in"
    refute has_element?(view, "#learnings-digest-picker")

    %{workspace: workspace} = connect_slack_channel(project)
    stub_slack(team_id: workspace.external_id, channels: [{"C_LEARN", "rail-learnings"}])

    {:ok, _project} =
      Rail.Projects.update_project(system_scope(), project, %{
        "learnings_slack_workspace_id" => workspace.id,
        "learnings_channel_external_id" => "C_LEARN"
      })

    {:ok, view, _html} = live(conn, ~p"/learnings")
    assert has_element?(view, "span#learnings-digest-link", "#rail-learnings")
    refute has_element?(view, "#learnings-digest-link", "#rail-feedback")

    Repo.insert!(%CuratorPass{
      project_id: project.id,
      started_at: DateTime.utc_now(),
      finished_at: DateTime.utc_now(),
      digest_permalink: "https://slack.example/p1"
    })

    {:ok, view, _html} = live(conn, ~p"/learnings")
    assert has_element?(view, "a#learnings-digest-link[href='https://slack.example/p1']", "#rail-learnings")
  end

  test "an admin picks where the digest posts from the footer, and another tab's pick redraws it", %{
    conn: conn,
    project: project
  } do
    {:ok, admin} =
      Users.register_oauth_user(%{
        github_id: "llv-admin",
        login: "ada",
        name: "Ada Admin",
        email: "ada@llv.example",
        admin: true
      })

    conn = log_in_user(conn, admin)
    %{workspace: workspace} = connect_slack_channel(project)
    stub_slack(team_id: workspace.external_id, channels: [{"C_LEARN", "rail-learnings"}, {"C_ENG", "eng"}])

    {:ok, view, _html} = live(conn, ~p"/learnings")
    Req.Test.allow(Rail.Slack, self(), view.pid)
    refute has_element?(view, "#learnings-digest-link")
    assert has_element?(view, "#learnings-digest-picker-trigger", "Post digest to Slack")

    view |> element("#learnings-digest-picker-trigger") |> render_click()
    assert has_element?(view, "#learnings-digest-picker[phx-click-away=close]")
    assert has_element?(view, "#learnings-digest-picker-none .pi-check-bold")
    refute has_element?(view, "#learnings-digest-picker-permalink")

    view |> element("#learnings-digest-picker-channel-C_LEARN") |> render_click()
    assert has_element?(view, "#learnings-digest-picker-trigger", "06:00 digest in")
    assert has_element?(view, "#learnings-digest-picker-trigger", "#rail-learnings")
    refute has_element?(view, "#learnings-digest-picker-saved")

    assert {:ok, %{learnings_channel_external_id: "C_LEARN"}} = Rail.Projects.get_project(project.id)

    Repo.insert!(%CuratorPass{
      project_id: project.id,
      started_at: DateTime.utc_now(),
      finished_at: DateTime.utc_now(),
      digest_permalink: "https://slack.example/p1"
    })

    {:ok, view, _html} = live(conn, ~p"/learnings")
    Req.Test.allow(Rail.Slack, self(), view.pid)
    view |> element("#learnings-digest-picker-trigger") |> render_click()

    assert has_element?(
             view,
             "a#learnings-digest-picker-permalink[href='https://slack.example/p1']",
             "Open today's digest in Slack"
           )

    {:ok, project} = Rail.Projects.get_project(project.id)

    {:ok, _project} =
      Rail.Projects.update_project(system_scope(), project, %{
        "learnings_slack_workspace_id" => workspace.id,
        "learnings_channel_external_id" => "C_ENG"
      })

    assert has_element?(view, "#learnings-digest-picker-trigger", "#eng")

    conn = Plug.Conn.put_session(conn, :selected_project_id, nil)
    {:ok, view, _html} = live(conn, ~p"/learnings")
    refute has_element?(view, "#learnings-digest-picker")
  end

  test "a page load asks Slack for the channel's name once, and a broadcast that leaves it alone asks nothing", %{
    conn: conn,
    project: project
  } do
    %{workspace: workspace} = connect_slack_channel(project)

    {:ok, project} =
      Rail.Projects.update_project(system_scope(), project, %{
        "learnings_slack_workspace_id" => workspace.id,
        "learnings_channel_external_id" => "C_LEARN"
      })

    test = self()

    Req.Test.stub(Rail.Slack, fn conn ->
      send(test, {:asked_slack, conn.request_path})
      Req.Test.json(conn, %{"ok" => true, "channel" => %{"id" => "C_LEARN", "name" => "rail-learnings"}})
    end)

    assert conn |> get(~p"/learnings") |> html_response(200) =~ "#C_LEARN"
    refute_received {:asked_slack, _path}

    {:ok, view, _html} = live(conn, ~p"/learnings")
    assert has_element?(view, "span#learnings-digest-link", "#rail-learnings")
    assert_received {:asked_slack, "/api/conversations.info"}
    refute_received {:asked_slack, _path}

    Req.Test.allow(Rail.Slack, self(), view.pid)
    Phoenix.PubSub.broadcast(Rail.PubSub, "learnings", {:learnings_changed, project.id})
    {:ok, _project} = Rail.Projects.update_project(system_scope(), project, %{"name" => "Renamed"})

    assert has_element?(view, "span#learnings-digest-link", "#rail-learnings")
    refute_received {:asked_slack, _path}
  end

  test "a change from another writer updates an open page", %{conn: conn, project: project} do
    {:ok, view, _html} = live(conn, ~p"/learnings?status=provisional")
    refute has_element?(view, "[data-qa=learning-card]")

    task = learnings_task(project, "LLV-2")

    {:ok, [rule]} =
      Learnings.record_corrections(task, [
        %DiffComment{id: "dcm_llv", path: "a.ex", line_text: "x", body: "Say why"}
      ])

    assert has_element?(view, "#learning-card-#{rule.id}", "Say why")
    assert has_element?(view, "#learning-sources", "Diff comment")
    send(view.pid, :unrelated)
    assert render(view) =~ "Say why"
    assert [%Observation{}] = Repo.all(from o in Observation, where: o.task_id == ^task.id)
  end

  describe "every kind of proposal, read in full" do
    setup %{project: project} do
      provisional =
        learning(project, %{rule: "Never call Repo.insert! in a test", kind: :convention}, status: :provisional)

      active = learning(project, %{rule: "Order findings by severity", kind: :decision})
      other = learning(project, %{rule: "Order findings by file", kind: :decision})

      rewrite_draft =
        learning(project, %{rule: "Tests build rows with builders", why: "Rows stay valid", kind: :convention},
          status: :proposed
        )

      add_draft = learning(project, %{rule: "Read git objects with :zlib", kind: :environment}, status: :proposed)
      task = learnings_task(project, "PRV-1")

      evidence =
        for attrs <- [
              %{task_id: task.id, source_kind: :diff_comment, text: "use the factory here"},
              %{
                source_kind: :pr_review_comment,
                text: "factory, not Repo",
                source_url: "https://github.com/x/y/pull/121#r1",
                actor_name: "dana-gh"
              },
              %{source_kind: :pr_review, text: "looks fine", source_url: "https://github.com/x/y/discussions/3"},
              %{source_kind: :extraction, text: "a lesson"}
            ] do
          Repo.insert!(struct(Observation, Map.put(attrs, :project_id, project.id)))
        end

      pass = Repo.insert!(%CuratorPass{project_id: project.id, started_at: ~U[2026-10-03 06:00:00.000000Z]})

      proposals =
        for attrs <- [
              %{action: :rewrite, learning_id: rewrite_draft.id, target_ids: [provisional.id], title: "Say it once"},
              %{
                action: :conflict,
                learning_id: active.id,
                target_ids: [other.id],
                summary: "RAIL-46 and RAIL-63 disagree"
              },
              %{action: :promote, learning_id: active.id, promote_to: :role_prompt, summary: "Broken 3 times"},
              %{
                action: :add,
                learning_id: add_draft.id,
                evidence_ids: Enum.map(evidence, & &1.id),
                curator_pass_id: pass.id
              }
            ],
            into: %{} do
          {attrs.action, Repo.insert!(struct(LearningProposal, Map.put(attrs, :project_id, project.id)))}
        end

      %{proposals: proposals}
    end

    test "each opens with what it would change and what it rests on", %{conn: conn, proposals: proposals} do
      conn = Plug.Conn.put_session(conn, :selected_project_id, nil)
      {:ok, view, _html} = live(conn, ~p"/learnings")

      for action <- ["Rewrite", "Conflict", "Promote", "Add"],
          do: assert(has_element?(view, "[data-qa=proposal-action]", action))

      {:ok, view, _html} = live(conn, ~p"/learnings/proposals/#{proposals.rewrite.id}")
      assert has_element?(view, "[data-qa=proposal-removed]", "Never call Repo.insert! in a test")
      assert has_element?(view, "[data-qa=proposal-removed]", "Provisional")
      assert has_element?(view, "[data-qa=proposal-draft]", "Rows stay valid")

      {:ok, view, _html} = live(conn, ~p"/learnings/proposals/#{proposals.conflict.id}")
      assert has_element?(view, "[data-qa=proposal-subject]", "Order findings by severity")
      assert has_element?(view, "[data-qa=proposal-subject]", "Order findings by file")
      assert has_element?(view, "#proposal-detail", "RAIL-46 and RAIL-63 disagree")
      refute has_element?(view, "#edit-proposal-button")

      {:ok, view, _html} = live(conn, ~p"/learnings/proposals/#{proposals.promote.id}")
      assert has_element?(view, "#proposal-promote", "Approving opens an issue to make this a role prompt")

      {:ok, view, _html} = live(conn, ~p"/learnings/proposals/#{proposals.add.id}")
      assert [_one] = Regex.scan(~r/data-qa="proposal-draft"/, render(view))
      refute has_element?(view, "[data-qa=proposal-subject]")
      assert has_element?(view, "#proposal-detail", "Curator, Oct 3 06:00")
      assert has_element?(view, "#proposal-evidence", "Evidence · 4")
      assert has_element?(view, "#proposal-evidence", "PRV-1")
      assert has_element?(view, "#proposal-evidence", "PR #121")
      assert has_element?(view, "#proposal-evidence", "GitHub")
      assert has_element?(view, "#proposal-evidence", "PR review comment: “factory, not Repo”, dana-gh")
    end
  end

  test "a rule's sources link back to where they came from, and the proposal that activated it", %{
    conn: conn,
    project: project,
    user: user
  } do
    draft = learning(project, %{rule: "Tests use the factory", kind: :convention}, status: :proposed)

    for {attrs, n} <-
          Enum.with_index([
            %{
              source_kind: :pr_review_comment,
              text: "factory, not Repo",
              source_url: "https://github.com/x/y/pull/121#r1",
              actor_name: "dana-gh"
            },
            %{source_kind: :extraction, text: "seen again"}
          ]) do
      Repo.insert!(
        struct(Observation, Map.merge(attrs, %{project_id: project.id, learning_id: draft.id, source_id: "src_#{n}"}))
      )
    end

    proposal =
      Repo.insert!(%LearningProposal{
        project_id: project.id,
        action: :add,
        learning_id: draft.id,
        summary: "same correction 3 times"
      })

    {:ok, view, _html} = live(conn, ~p"/learnings/#{draft.id}")
    assert has_element?(view, "#learnings-segment-review[aria-pressed=true]")
    assert has_element?(view, "#learning-detail", "drafted")
    assert has_element?(view, "#learning-sources a[href='https://github.com/x/y/pull/121#r1']", "factory, not Repo")
    assert has_element?(view, "#learning-sources", "Seen in a finished task · Rail")

    {:ok, _approved} = Learnings.approve_learning_proposal(Rail.Scope.for_user(user), proposal)
    assert has_element?(view, "#learning-sources", "Approved · Dana Okafor")
    assert has_element?(view, "#learning-sources", "same correction 3 times")
    assert has_element?(view, "#learning-detail", "by Dana Okafor")

    curated = learning(project, %{rule: "Curated", kind: :convention}, status: :proposed)
    curated_proposal = Repo.insert!(%LearningProposal{project_id: project.id, action: :add, learning_id: curated.id})
    {:ok, _auto} = Learnings.approve_learning_proposal(system_scope(), curated_proposal)
    {:ok, view, _html} = live(conn, ~p"/learnings/#{curated.id}")
    assert has_element?(view, "#learning-sources", "Curator run · Curator")
    assert has_element?(view, "#learning-detail", "by the curator")
  end

  test "a rule or proposal that is not there opens nothing", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/learnings/lrn_none")
    refute has_element?(view, "#learning-detail")

    {:ok, view, _html} = live(conn, ~p"/learnings/proposals/lpr_none")
    refute has_element?(view, "#proposal-detail")
  end

  test "Keep rule from a second tab is told it was already decided, and the queue opens an override on its rule", %{
    conn: conn,
    user: user,
    project: granted
  } do
    {:ok, project} =
      Rail.Projects.create_project(system_scope(), %{
        name: "Keep rule #{System.unique_integer([:positive])}",
        github_repo: "example/keep-rule",
        github_installation_id: 1,
        default_branch: "main",
        key: "KPR",
        clone_path: "/tmp/repos/keep-rule"
      })

    {:ok, _user} = Users.update_user(system_scope(), user, %{project_ids: [granted.id, project.id]})
    conn = Plug.Conn.put_session(conn, :selected_project_id, project.id)
    rule = learning(project, %{rule: "Don't flag docs", kind: :calibration})
    override = Repo.insert!(%LearningProposal{project_id: project.id, action: :override, learning_id: rule.id})

    {:ok, view, _html} = live(conn, ~p"/learnings")
    assert has_element?(view, "#learning-rule", "Don't flag docs")

    {:ok, view, _html} = live(conn, ~p"/learnings/#{rule.id}")

    # The other tab's ruling lands before its broadcast does.
    Repo.update_all(from(p in LearningProposal, where: p.id == ^override.id), set: [status: :rejected])
    view |> element("#keep-rule-button") |> render_click()
    assert has_element?(view, "#learnings-error", "Someone already decided this proposal.")

    send(view.pid, {:learnings_changed, "prj_elsewhere"})
    assert has_element?(view, "#learnings-error", "Someone already decided this proposal.")
  end

  test "the list says when it shows only the newest, and a card says what broke its rule", %{conn: conn, project: project} do
    {:ok, lead} = Rail.Roles.get_role(project_id: project.id, stage: :review_lead)

    for n <- 1..100,
        do: learning(project, %{rule: "Rule #{n}", kind: :convention}, activated_at: ~U[2026-01-01 00:00:00Z])

    pinned = learning(project, %{rule: "Take the scope first", kind: :convention, pinned: true})
    task = learnings_task(project, "BRK-1", :review)

    {:ok, run} =
      Pipeline.create_run(%{task_id: task.id, role_id: lead.id, status: :finished, started_at: DateTime.utc_now()})

    Learnings.retrieve_learnings(run, [])

    {:ok, _scope} =
      Pipeline.save_finding(task, %{
        key: "scope",
        kind: :code,
        raised_by: :code_reviewer,
        title: "No scope",
        problem: "A task with no worktree crashes the page.",
        file: "lib/a.ex",
        line: 3,
        fix: "Guard the nil in the action.",
        why: "It crashes.",
        rule: "Every caller handles a missing worktree.",
        severity: :major,
        recommendation: :fix,
        checklist_rule: pinned.id,
        places: [%{file: "lib/a.ex", line: 3, label: "handle/1"}],
        evidence: [%{name: "The clause", kind: :code, file: "lib/a.ex", line: 3}]
      })

    {:ok, view, _html} = live(conn, ~p"/learnings?status=active")
    assert has_element?(view, "#learnings-match-line", "Newest 100 of 101 active")
    assert has_element?(view, "#learning-card-#{pinned.id}", "1 run")
    assert has_element?(view, "#learning-card-#{pinned.id} .text-red-600", "1 broken")
  end

  test "a rule given to one run reads 1 retrieval, and a diff comment's block in its why is set as code", %{
    conn: conn,
    project: project
  } do
    task = learnings_task(project, "LLV-9")

    comment = %DiffComment{
      id: "dcm_llv_9",
      path: "lib/a.ex",
      line_text: "Repo.insert!(row)",
      context_text: "  + rows = build()\n> + Repo.insert!(row)",
      body: "Use the factory here"
    }

    {:ok, [rule]} = Learnings.record_corrections(task, [comment])
    {:ok, role} = Rail.Roles.get_role(project_id: project.id, stage: :engineer)

    {:ok, run} =
      Pipeline.create_run(%{task_id: task.id, role_id: role.id, status: :running, started_at: DateTime.utc_now()})

    Repo.insert!(%Rail.Learnings.Schemas.LearningRetrieval{run_id: run.id, learning_id: rule.id})

    {:ok, view, _html} = live(conn, ~p"/learnings/#{rule.id}")
    assert has_element?(view, "#learning-figures", "1 retrieval")
    refute has_element?(view, "#learning-figures", "1 retrievals")
    assert has_element?(view, "#learning-why", "From a diff comment on lib/a.ex:")
    assert view |> element("#learning-why pre.font-mono") |> render() =~ "  + rows = build()\n&gt; + Repo.insert!(row)"
  end

  test "a rule from a design comment shows its source and its element in a sandboxed preview, never as markup", %{
    conn: conn,
    project: project,
    user: user
  } do
    task = learnings_task(project, "LLV-10")
    html = ~s{<h2 id="needs">Needs you <script>alert("x")</script><button onclick="go()">3</button></h2>}

    comment = %PlanComment{
      id: "pcm_llv_10",
      target: :design,
      user_id: user.id,
      option_key: "waiting-lanes",
      selector: "#needs",
      element_text: "Needs you 3",
      element_tag: "h2",
      body: "Say how long the oldest one has waited.",
      capture: %PlanCommentCapture{html: html, width: 180, height: 22}
    }

    {:ok, [rule]} = Learnings.record_corrections(task, [comment])

    {:ok, view, page} = live(conn, ~p"/learnings/#{rule.id}")

    assert has_element?(view, "#learning-rule", "Say how long the oldest one has waited.")
    assert has_element?(view, "[data-qa=learning-status]", "Provisional")
    assert has_element?(view, "#learning-detail", "Designer")
    assert has_element?(view, "#learning-sources", "Design comment · Dana Okafor")
    assert has_element?(view, ~s(#learning-sources a[href="/tasks/#{task.id}"]), "LLV-10")
    assert has_element?(view, "#learning-why", ~s(From a design comment on waiting-lanes, `#needs` "Needs you 3":))
    refute has_element?(view, "#learning-why pre")
    assert has_element?(view, ~s(#learning-element iframe[sandbox=""][srcdoc]))

    doc = Floki.parse_document!(page)

    assert doc |> Floki.find("#learning-element iframe") |> Floki.attribute("srcdoc") ==
             ["<style>html,body{margin:0;overflow:hidden}body>*:first-child{margin:0}</style>" <> html]

    assert Floki.find(doc, "#learning-detail script") == []
    assert Floki.find(doc, "#learning-detail button[onclick]") == []
  end

  test "a diff comment's rule still shows its code block and no preview", %{conn: conn, project: project} do
    task = learnings_task(project, "LLV-11")
    comment = %DiffComment{id: "dcm_llv_11", path: "lib/a.ex", line_text: "x", context_text: "> + x", body: "Name it"}
    {:ok, [rule]} = Learnings.record_corrections(task, [comment])

    {:ok, view, _html} = live(conn, ~p"/learnings/#{rule.id}")

    assert has_element?(view, "#learning-why pre.font-mono", "> + x")
    refute has_element?(view, "#learning-element")
  end
end
