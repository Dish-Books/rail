defmodule RailWeb.Live.PlanStageTest do
  use RailWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Rail.Pipeline.Utils.BuildTask

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Round
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Scope
  alias Rail.Users

  # The smallest plan the structure allows: one decision, one card and one criterion, and no data changes.
  @plan """
  ## Implementation plan

  ### Approach

  All of it.

  ### Decisions

  - Decision: one module changes.

  ### Changes

  #### `lib/rail.ex`

  Does all of it.

  ### Acceptance criteria

  - 1: `lib/rail.ex`

  ### Verification

  - `lib/rail_test.exs`: covers all of it.
  """

  setup %{conn: conn, project: project} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_plan_stage",
        login: "plan_stage",
        email: "plan_stage@example.com",
        admin: true
      })

    {:ok, role} = Roles.get_role(project_id: project.id, stage: :plan)

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_plan_stage_1", "identifier" => "PST-1", "title" => "Plan Stage Issue"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(Scope.for_system(), project, %{description: "Plan Stage Issue"})
    {:ok, task} = Pipeline.create_task(issue, :plan)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :finished,
        stage_outcome: :done,
        conversation_id: "sess_plan_stage",
        started_at: DateTime.utc_now()
      })

    {:ok, _ticket} = Pipeline.save_plan(task, %{title: "Previews", description: "## Acceptance criteria\n\n- One\n"})
    {:ok, _plan} = Pipeline.save_plan(task, %{plan: @plan})

    %{conn: log_in_user(conn, user), user: user, task: task, run: run}
  end

  test "an approved plan reads as approved, its conversation readable but closed", %{
    conn: conn,
    user: user,
    task: task,
    run: run
  } do
    Pipeline.append_run_events(run.id, nil, ["[human:#{user.id}] Split the export from the import."])

    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}?item=plan")
    assert has_element?(view, "#plan-chat textarea")

    {:ok, task} = Pipeline.update_task(task, %{stage: :split})
    Repo.update_all(from(r in Round, where: r.task_id == ^task.id), set: [approved_at: DateTime.utc_now()])
    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}?item=plan&agent=plan")
    assert has_element?(view, "#review-item-plan[title='Plan: Approved']")
    assert has_element?(view, "#plan-chat #conversation-closed", "take messages")
    assert has_element?(view, "#plan-chat", "Split the export from the import.")
    refute has_element?(view, "#plan-chat textarea")

    # A page drawn before approval can still send, and the closed conversation takes nothing.
    view |> with_target("#conversation-tab-root") |> render_hook("send_chat", %{"message" => "Use semicolons."})
    refute Enum.any?(Pipeline.list_run_events(run), &(&1.line =~ "Use semicolons."))
  end

  test "the page has the ticket, the design and the plan, and no Split section", %{
    conn: conn,
    task: task
  } do
    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    assert has_element?(view, "#plan-section-ticket")
    assert has_element?(view, "#plan-section-design")
    assert has_element?(view, "#plan-section-plan #plan-plan")
    refute has_element?(view, "#plan-section-split")
  end

  test "a pull request handed over shows the issue's ticket and where it came from, with nothing to approve", %{
    conn: conn,
    user: user,
    project: project
  } do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_pst_pr", "identifier" => "PST-20", "title" => "Hosts on the Sandboxes page"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{title: "Hosts on the Sandboxes page"})
    {:ok, task} = Pipeline.create_task(issue, :review)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    {:ok, task} =
      Pipeline.update_task(task, %{
        worktree_name: "michael/pst-20-hosts-on-the-sandboxes-page-and-a-long-branch-name",
        pr_number: 212,
        pr_url: "https://github.com/example/test-seed/pull/212",
        submitted_by_id: user.id,
        submitted_at: DateTime.utc_now(),
        submitted_head: "4e1c2a9f00d"
      })

    Repo.insert!(%Round{
      task_id: task.id,
      number: 1,
      approved_at: DateTime.utc_now(),
      approved_by_id: user.id,
      ticket: %Round.Ticket{title: "Hosts on the Sandboxes page", description: "Each row names its host."}
    })

    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}?item=plan")

    assert has_element?(view, "#review-item-plan[title='Plan: From PR #212, no plan']")
    assert has_element?(view, "#plan-section-ticket-status", "From the issue")
    assert has_element?(view, "#plan-ticket-title", "Hosts on the Sandboxes page")
    assert has_element?(view, "#plan-section-design-status", "None")
    assert has_element?(view, "#plan-design-submitted", "None. Submitted work has no design options.")
    assert has_element?(view, "#plan-section-plan-status", "From a pull request")
    assert has_element?(view, "#plan-submitted", "Handed to Rail by plan_stage")
    assert has_element?(view, "#plan-submitted-pr[href='https://github.com/example/test-seed/pull/212']", "#212")

    assert has_element?(
             view,
             "#plan-submitted-branch",
             "michael/pst-20-hosts-on-the-sandboxes-page-and-a-long-branch-name"
           )

    # Nothing between the sha and its full stop.
    assert view |> element("#plan-submitted-head") |> render() =~ ~r{>4e1c2a9</span>\z}
    assert has_element?(view, "#plan-submitted", "There is no plan, so the ticket is the whole specification.")
    refute has_element?(view, "#plan-design-pending")
    refute has_element?(view, "#plan-plan-pending")
    refute render(view) =~ "Plan stopped"
    refute has_element?(view, "#task-approve-plan")
    refute has_element?(view, "#task-plan-unapproved")

    {:ok, _named} = Users.update_user(system_scope(), user, %{name: "Michael Gutierrez"})
    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}?item=plan")
    assert has_element?(view, "#plan-submitted", "Handed to Rail by Michael Gutierrez,")

    {:ok, _left} = Pipeline.update_task(task, %{submitted_by_id: nil})
    Repo.insert!(%Round{task_id: task.id, number: 2, plan: "Fix it.", approved_at: DateTime.utc_now()})
    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}?item=plan&round=1")
    assert has_element?(view, "#plan-round-select option[value='1']", "Round 1 · the pull request")
    assert has_element?(view, "#plan-submitted", "Handed to Rail,")
  end

  test "a child's Plan tab shows its approved part as a sheet, under a notice naming every child it waits on", %{
    conn: conn,
    project: project
  } do
    for {identifier, title} <- [
          {"PST-10", "Work on PST-10"},
          {"PST-11", "Child PST-11"},
          {"PST-12", "Child PST-12"},
          {"PST-13", "Child PST-13"}
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

    {:ok, parent_issue} = Issues.create_issue(system_scope(), project, %{title: "Work on PST-10"})
    {:ok, parent} = Pipeline.create_task(parent_issue, :split)
    parent = Repo.preload(parent, [:issue, :project])

    [_first, _second, third] =
      for {{identifier, builds_on}, number} <- Enum.with_index([{"PST-11", []}, {"PST-12", []}, {"PST-13", [1, 2]}], 1) do
        attrs = %{title: "Child #{identifier}", parent: parent_issue}
        {:ok, issue} = Issues.create_issue(system_scope(), project, attrs)

        {:ok, child} =
          issue.project
          |> build_task(issue, %{stage: :engineer, split_position: number, builds_on: builds_on})
          |> Ecto.Changeset.put_change(:parent_task_id, parent.id)
          |> Repo.insert()

        Repo.preload(child, [:issue, :project])
      end

    on_exit(fn -> File.rm_rf(parent.scratch_path) end)

    Repo.insert!(%Round{
      task_id: third.id,
      number: 1,
      plan: sheet_plan(),
      approved_at: DateTime.utc_now(),
      ticket: %Round.Ticket{title: "A part", description: "Its criteria."}
    })

    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{parent.id}?child=PST-13&item=plan")

    assert has_element?(view, "#child-plan-waiting", "Starts when PST-11 and PST-12 merge.")
    assert has_element?(view, "#child-plan-approved", "Approved in PST-10 · part 3 of 3")
    assert has_element?(view, "#child-plan #plan-sheet #plan-3-group-pipeline")
  end

  test "a plan in the new sections has no diagrams and no In this plan box, and reads its criteria off the ticket", %{
    conn: conn,
    task: task
  } do
    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}?item=plan")

    assert has_element?(view, "#plan-plan #plan-sheet #plan-group-lib #plan-card-1", "lib/rail.ex")
    assert has_element?(view, "#plan-sheet [data-qa='plan_criterion']", "One")
    refute has_element?(view, "#plan-plan figure")
    refute has_element?(view, "#plan-summary")
    refute has_element?(view, "#plan-plan", "In this plan")
  end

  test "a plan saved before its ticket still lays out, its criteria read by their numbers", %{conn: conn, task: task} do
    Repo.update_all(from(r in Round, where: r.task_id == ^task.id), set: [ticket: nil])
    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}?item=plan")

    assert has_element?(view, "#plan-sheet [data-qa='plan_criterion']", "Criterion 1")
    refute has_element?(view, "#plan-sheet [data-qa='plan_criterion']", "Not covered")
  end

  test "the + on an Approach paragraph, a decision, a card's prose, a sketch line and a criterion opens the box under it",
       %{conn: conn, task: task} do
    {:ok, _ticket} =
      Pipeline.save_plan(task, %{title: "Previews", description: "## Acceptance criteria\n\n- One\n- Two\n- Three\n"})

    {:ok, _plan} = Pipeline.save_plan(task, %{plan: sheet_plan()})
    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}?item=plan")

    for {label, body} <- [
          {"Approach, paragraph 1", "Why EnterStage?"},
          {"Decisions, item 2", "Keep the history."},
          {"File 1, paragraph 1", "Idle how?"},
          {"File 1, sketch line 2", "Pass the note."},
          {"Criterion 2", "Nothing covers this."},
          {"Criterion 3", "Test it too."}
        ] do
      view |> element("#plan-sheet button[aria-label='Comment on #{label}']") |> render_click()
      assert has_element?(view, "#plan-sheet [data-qa='line_comments'] form[data-qa='document_comment_form']")
      view |> form("#plan-sheet [data-qa='document_comment_form']", %{"body" => body}) |> render_submit()

      line =
        view |> element("#plan-sheet button[aria-label='Comment on #{label}']") |> render() |> Floki.parse_fragment!()

      [key] = Floki.attribute(line, "phx-value-key")
      assert has_element?(view, "#line-plan-#{key} + [data-qa='line_comments'] [data-qa='document_comment']", body)
    end

    assert has_element?(view, "#plan-card-1 [data-qa='plan_card_sketch'][open]")
    assert has_element?(view, "#plan-criteria [data-qa='plan_criterion']", "Not covered")
  end

  test "a plan saved before this change, diagrams and all, shows as lines that take a comment", %{
    conn: conn,
    task: task
  } do
    old =
      "## Implementation plan\n\n### Approach\n\nExtend it.\n\n### Change diagram\n\n```mermaid\nflowchart LR\n  A --> B\n```\n\n" <>
        "### File-level changes\n\n- `lib/rail.ex`: extends it.\n\n### Verification\n\n- Works."

    Repo.update_all(from(r in Round, where: r.task_id == ^task.id), set: [plan: old])
    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}?item=plan")

    refute has_element?(view, "#plan-sheet")
    assert has_element?(view, "#plan-plan [data-kind='code']", "A --> B")

    view |> element("#plan-plan button[aria-label='Comment on Code line 2']") |> render_click()
    view |> form("#plan-plan [data-qa='document_comment_form']", %{"body" => "Which B?"}) |> render_submit()
    assert has_element?(view, "#plan-plan [data-kind='code'] [data-qa='document_comment']", "Which B?")
  end
end
