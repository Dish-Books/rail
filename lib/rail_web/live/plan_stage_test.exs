defmodule RailWeb.Live.PlanStageTest do
  use RailWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Rail.Pipeline.Utils.BuildTask

  alias Rail.Git
  alias Rail.Issues
  alias Rail.Issues.Schemas.IssueStage
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
    assert has_element?(view, "#plan-tab-plan")
    refute has_element?(view, "#plan-tab-split")
    refute has_element?(view, "#plan-section-split")

    assert ["plan-tab-ticket", "plan-tab-design", "plan-tab-plan"] ==
             view |> render() |> Floki.parse_document!() |> Floki.attribute("[data-qa='plan_tab']", "id")

    refute has_element?(view, "[data-qa='plan_tab_off']")
    refute has_element?(view, "#plan-ticket-from-issue")
  end

  test "a file a custom stage saved before Plan heads the tabs, saying when it was saved and which stages get it", %{
    conn: conn,
    task: task
  } do
    stages = [
      %IssueStage{stage: :custom, name: "Missing strings", prompt: "List the keys."},
      %IssueStage{stage: :plan},
      %IssueStage{stage: :engineer},
      %IssueStage{stage: :custom, name: "License check", prompt: "Check each license."},
      %IssueStage{stage: :review}
    ]

    Repo.preload(task, :issue).issue
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.put_embed(:stages, stages)
    |> Repo.update!()

    File.mkdir_p!(Path.join(task.scratch_path, "stages"))

    File.write!(
      Path.join([task.scratch_path, "stages", "1-missing-strings.md"]),
      "12 keys in `en.json` have no German entry.\n"
    )

    File.write!(Path.join([task.scratch_path, "stages", "4-license-check.md"]), "Not Plan's to show.\n")

    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}?item=plan")

    assert ["plan-tab-stage-1", "plan-tab-ticket", "plan-tab-design", "plan-tab-plan"] ==
             view |> render() |> Floki.parse_document!() |> Floki.attribute("[data-qa='plan_tab']", "id")

    assert has_element?(view, "#plan-tab-stage-1", "Missing strings")
    assert has_element?(view, "#plan-earlier-stage-1", "Earlier stage")
    assert has_element?(view, "#plan-earlier-stage-1", "Plan, Implement, License check and Review get this file")
    assert has_element?(view, "#plan-earlier-stage-1 code", "en.json")
    refute has_element?(view, "#plan-section-stage-4")

    # Before Plan has saved its plan, the earlier stage's file is what the tab opens on.
    Repo.update_all(from(r in Round, where: r.task_id == ^task.id), set: [plan: nil])
    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}?item=plan")
    assert has_element?(view, "#plan-tab-stage-1[aria-selected='true']")
  end

  describe "a task whose workflow turned steps off" do
    setup %{task: task} do
      skipping = fn steps ->
        Repo.preload(task, :issue).issue |> Ecto.Changeset.change(skipped_steps: steps) |> Repo.update!()
      end

      %{skipping: skipping}
    end

    test "with Product off the Ticket tab is the issue, saying why, and its lines take no comment", %{
      conn: conn,
      task: task,
      skipping: skipping
    } do
      issue = skipping.([:product])
      issue |> Ecto.Changeset.change(description: "Update the **dependencies**.") |> Repo.update!()

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}?item=plan")

      assert has_element?(
               view,
               "#plan-ticket-from-issue",
               "Product is off for this workflow, so the issue's description is the ticket."
             )

      assert has_element?(view, "#plan-ticket-issue-title", "Plan Stage Issue")
      assert has_element?(view, "#plan-ticket-from-issue strong", "dependencies")
      refute has_element?(view, "[data-qa='plan_ticket']")
      refute has_element?(view, "[data-qa='plan_tab_off']")
    end

    test "with Design off the Design tab is marked off and says so", %{conn: conn, task: task, skipping: skipping} do
      skipping.([:design])

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}?item=plan")

      assert has_element?(view, "#plan-tab-design #plan-tab-design-off[title='Off for this workflow']")
      assert has_element?(view, "#plan-design-off", "Off for this workflow")
      assert has_element?(view, "#plan-design-off", "This workflow turned Design off")
      refute has_element?(view, "#plan-design-pending")
      refute has_element?(view, "#plan-tab-plan-off")
    end

    test "with Architect off the Plan tab is marked off and the status asks for the ticket", %{
      conn: conn,
      task: task,
      skipping: skipping
    } do
      skipping.([:product, :architect])
      Repo.update_all(from(r in Round, where: r.task_id == ^task.id), set: [plan: nil])

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}?item=plan")

      assert has_element?(view, "#plan-tab-plan-off")
      assert has_element?(view, "#plan-plan-off", "This workflow turned Architect off")
      assert has_element?(view, "#plan-plan-off", "Engineer builds from the issue.")
      refute has_element?(view, "#plan-plan-pending")
      assert has_element?(view, "[data-qa='task_status_chip']", "Review the ticket")
    end
  end

  test "every part is a panel on the page with only the opening one shown, and a tab switches in the browser alone", %{
    conn: conn,
    task: task
  } do
    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}?item=plan")

    assert has_element?(view, "#plan-section-plan[role='tabpanel']:not(.hidden) #plan-plan")
    assert has_element?(view, "#plan-section-ticket.hidden [data-qa='plan_ticket']")
    assert has_element?(view, "#plan-section-design.hidden")
    assert has_element?(view, "#plan-tab-plan[aria-selected='true']")
    assert has_element?(view, "#plan-tab-ticket[aria-selected='false']")

    doc = view |> render() |> Floki.parse_document!()

    # Only these four on every tab, so nothing goes to the server.
    for id <- ["ticket", "design", "plan"] do
      [click] = Floki.attribute(doc, "#plan-tab-#{id}", "phx-click")
      hidden = "#plan-panels-#{task.id} > [role='tabpanel']:not(#plan-section-#{id})"
      section = "#plan-section-#{id}"
      unselected = "#plan-tabs-#{task.id} > [role='tab']:not(#plan-tab-#{id})"
      tab = "#plan-tab-#{id}"

      assert [
               ["hide", %{"to" => ^hidden}],
               ["show", %{"to" => ^section, "display" => "block"}],
               ["set_attr", %{"to" => ^unselected, "attr" => ["aria-selected", "false"]}],
               ["set_attr", %{"to" => ^tab, "attr" => ["aria-selected", "true"]}]
             ] = Jason.decode!(click)
    end
  end

  test "after the first render the browser alone keeps which panel shows and which tab reads selected", %{
    conn: conn,
    task: task
  } do
    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}?item=plan")
    doc = view |> render() |> Floki.parse_document!()

    assert [_ticket, _design, _plan] =
             panels = Floki.attribute(doc, "#plan-panels-#{task.id} > [role='tabpanel']", "phx-mounted")

    assert Enum.all?(panels, &(Jason.decode!(&1) == [["ignore_attrs", %{"attrs" => ["class"]}]]))

    assert [_ticket, _design, _plan] = tabs = Floki.attribute(doc, "#plan-tabs-#{task.id} > [role='tab']", "phx-mounted")
    assert Enum.all?(tabs, &(Jason.decode!(&1) == [["ignore_attrs", %{"attrs" => ["aria-selected"]}]]))
  end

  test "the page opens on Ticket before a plan is saved, and a plan saved after leaves it there", %{
    conn: conn,
    task: task
  } do
    Repo.update_all(from(r in Round, where: r.task_id == ^task.id), set: [plan: nil])
    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}?item=plan")
    assert has_element?(view, "#plan-section-ticket:not(.hidden)")
    assert has_element?(view, "#plan-section-plan.hidden #plan-plan-pending")

    {:ok, _plan} = Pipeline.save_plan(task, %{plan: @plan})
    _settled = render(view)

    assert has_element?(view, "#plan-section-plan.hidden #plan-plan")
    assert has_element?(view, "#plan-section-ticket:not(.hidden)")
    assert has_element?(view, "#plan-tab-ticket[aria-selected='true']")
    assert has_element?(view, "#plan-tab-plan[aria-selected='false']")
  end

  test "while three options wait for a pick the page opens on Design, whose tab raises a hand through every save", %{
    conn: conn,
    task: task
  } do
    dir = Path.join(task.scratch_path, "design")
    File.mkdir_p!(dir)

    for key <- ["cards", "table", "timeline"] do
      File.write!(Path.join(dir, "#{key}.html"), "<h1>#{key}</h1>")
      File.write!(Path.join(dir, "#{key}.png"), "png bytes")
      {:ok, _option} = Pipeline.save_design_option(task, %{key: key, title: key, summary: "#{key}."})
    end

    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}?item=plan")
    assert has_element?(view, "#plan-section-design:not(.hidden) #design-options")
    assert has_element?(view, "#plan-tab-design[aria-selected='true'] #plan-tab-design-waiting")
    refute has_element?(view, "#plan-tab-ticket [data-qa='plan_tab_waiting']")
    refute has_element?(view, "#plan-tab-plan [data-qa='plan_tab_waiting']")

    {:ok, _plan} = Pipeline.save_plan(task, %{plan: String.replace(@plan, "All of it.", "Revised.")})
    _settled = render(view)

    assert has_element?(view, "#plan-section-plan.hidden #plan-plan", "Revised.")
    assert has_element?(view, "#plan-section-design:not(.hidden)")
    assert has_element?(view, "#plan-tab-design-waiting")

    File.write!(Path.join(dir, "picked"), "table")
    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}?item=plan")
    refute has_element?(view, "#plan-tab-design-waiting")
    assert has_element?(view, "#plan-section-plan:not(.hidden)")
    assert has_element?(view, "#plan-section-design.hidden")
  end

  test "a tab Plan is writing carries a spinner and no hand", %{conn: conn, task: task, run: run} do
    Repo.update_all(from(r in Round, where: r.task_id == ^task.id), set: [ticket: nil, plan: nil])
    {:ok, _working} = Pipeline.update_run(run, %{status: :running, stage_outcome: :in_progress})
    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}?item=plan")

    assert has_element?(view, "#plan-tab-ticket-working", "being written")
    assert has_element?(view, "#plan-tab-design-working")
    refute has_element?(view, "#plan-tab-plan-working")
    refute has_element?(view, "[data-qa='plan_tab_waiting']")
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

  test "the plan's cards read New or Changed off the default branch, which a load with the same paths does not ask again",
       %{conn: conn, task: task} do
    {:ok, _plan} = Pipeline.save_plan(task, %{plan: sheet_plan()})

    # Once for the first render and once for the connected page; no later load asks again.
    expect(Git, :list_default_branch_paths, 2, fn %{github_repo: "example/test-seed"}, paths ->
      assert paths == [
               "lib/rail/pipeline.ex",
               "lib/rail/pipeline/actions/old_send_back.ex",
               "lib/rail/pipeline/actions/send_back_to_architect.ex",
               "lib/rail_web/live/review_stage.ex",
               "priv/repo/migrations/20261022000000_add_sent_back_note.exs"
             ]

      MapSet.new(["lib/rail/pipeline.ex"])
    end)

    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}?item=plan")

    assert has_element?(view, "#plan-card-1 [data-qa='plan_card_new']", "New")
    assert has_element?(view, "#plan-card-2 [data-qa='plan_card_changed']", "Changed")

    assert has_element?(
             view,
             "#plan-card-2 a[href='https://github.com/example/test-seed/blob/main/lib/rail/pipeline.ex']"
           )

    assert has_element?(view, "#plan-group-pipeline [data-qa='plan_group_count']", "1 new · 1 changed · 1 deleted")

    {:ok, _ticket} =
      Pipeline.save_plan(task, %{title: "Previews again", description: "## Acceptance criteria\n\n- One\n"})

    _settled = render(view)
    assert has_element?(view, "#plan-section-ticket", "Previews again")
    assert has_element?(view, "#plan-card-2 [data-qa='plan_card_changed']")
  end

  test "when the clone cannot say, the cards read neither New nor Changed and the groups count their files", %{
    conn: conn,
    task: task
  } do
    expect(Git, :list_default_branch_paths, 2, fn _project, ["lib/rail.ex"] -> nil end)
    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}?item=plan")

    refute has_element?(view, "#plan-card-1 [data-qa='plan_card_new']")
    refute has_element?(view, "#plan-card-1 [data-qa='plan_card_changed']")
    refute has_element?(view, "#plan-card-1 [data-qa='plan_card_link']")
    assert has_element?(view, "#plan-group-lib [data-qa='plan_group_count']", "1 file")
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

  describe "reviewed cards" do
    setup %{task: task} do
      {:ok, _plan} = Pipeline.save_plan(task, %{plan: sheet_plan()})
      %{path: "lib/rail/pipeline/actions/send_back_to_architect.ex"}
    end

    test "marking a card collapses it and moves both counts, and a second click on the same state changes nothing", %{
      conn: conn,
      user: user,
      task: task,
      path: path
    } do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}?item=plan")
      assert has_element?(view, "#plan-reviewed-count", "0 of 5 reviewed")
      assert has_element?(view, "#plan-card-1", "Refuses unless the task is at :review and idle.")

      toggle = element(view, "#plan-card-1 [data-qa='plan_card_reviewed']")
      [digest] = toggle |> render() |> Floki.parse_fragment!() |> Floki.attribute("button", "phx-value-digest")
      render_click(toggle)

      assert has_element?(view, "#plan-card-1 [data-qa='plan_card_reviewed'][aria-pressed='true']")
      refute has_element?(view, "#plan-card-1", "Refuses unless the task is at :review and idle.")
      refute has_element?(view, "#plan-card-1 [data-qa='plan_card_sketch']")
      assert has_element?(view, "#plan-reviewed-count", "1 of 5 reviewed")
      assert has_element?(view, "#plan-group-pipeline [data-qa='plan_group_reviewed']", "1 of 3 reviewed")
      assert has_element?(view, "#plan-group-web [data-qa='plan_group_reviewed']", "0 of 1 reviewed")

      # A double click, or a second tab, asks for the state already set.
      click = fn reviewed ->
        render_click(with_target(view, "#plan-stage"), "toggle_plan_file_reviewed", %{
          "path" => path,
          "digest" => digest,
          "reviewed" => reviewed
        })
      end

      click.("true")
      assert Git.list_viewed_files(user_scope(user: user), task, :plan) == %{path => digest}
      assert has_element?(view, "#plan-reviewed-count", "1 of 5 reviewed")

      view |> element("#plan-card-1 [data-qa='plan_card_reviewed']") |> render_click()
      click.("false")

      assert Git.list_viewed_files(user_scope(user: user), task, :plan) == %{}
      assert has_element?(view, "#plan-card-1 [data-qa='plan_card_reviewed'][aria-pressed='false']")
      assert has_element?(view, "#plan-card-1", "Refuses unless the task is at :review and idle.")
      assert has_element?(view, "#plan-reviewed-count", "0 of 5 reviewed")
    end

    test "a path that is not one of the plan's cards is ignored", %{conn: conn, user: user, task: task} do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}?item=plan")

      render_click(with_target(view, "#plan-stage"), "toggle_plan_file_reviewed", %{
        "path" => "lib/rail/not_in_the_plan.ex",
        "digest" => "any",
        "reviewed" => "true"
      })

      assert Git.list_viewed_files(user_scope(user: user), task, :plan) == %{}
      assert has_element?(view, "#plan-reviewed-count", "0 of 5 reviewed")
    end

    test "the marks are the reader's own: a reload keeps them and a teammate sees only theirs", %{
      conn: conn,
      task: task
    } do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}?item=plan")
      view |> element("#plan-card-1 [data-qa='plan_card_reviewed']") |> render_click()

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}?item=plan")
      assert has_element?(view, "#plan-card-1 [data-qa='plan_card_reviewed'][aria-pressed='true']")
      assert has_element?(view, "#plan-reviewed-count", "1 of 5 reviewed")

      {:ok, teammate} =
        Users.register_oauth_user(%{
          github_id: "gh_plan_stage_teammate",
          login: "plan_stage_teammate",
          email: "plan_stage_teammate@example.com",
          admin: true
        })

      assert {:ok, theirs, _html} = live(log_in_user(build_conn(), teammate), ~p"/tasks/#{task.id}?item=plan")
      assert has_element?(theirs, "#plan-card-1 [data-qa='plan_card_reviewed'][aria-pressed='false']")
      assert has_element?(theirs, "#plan-reviewed-count", "0 of 5 reviewed")

      theirs |> element("#plan-card-4 [data-qa='plan_card_reviewed']") |> render_click()

      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}?item=plan")
      assert has_element?(view, "#plan-card-4 [data-qa='plan_card_reviewed'][aria-pressed='false']")
    end

    test "a revision that changes a reviewed card opens it unmarked saying so, and leaves an unchanged one reviewed", %{
      conn: conn,
      task: task
    } do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}?item=plan")
      view |> element("#plan-card-1 [data-qa='plan_card_reviewed']") |> render_click()
      view |> element("#plan-card-4 [data-qa='plan_card_reviewed']") |> render_click()
      assert has_element?(view, "#plan-reviewed-count", "2 of 5 reviewed")
      refute has_element?(view, "[data-qa='plan_card_revised']")

      revised = String.replace(sheet_plan(), "Refuses unless the task is at `:review` and idle.", "Refuses unless idle.")
      {:ok, _plan} = Pipeline.save_plan(task, %{plan: revised})
      _settled = render(view)

      assert has_element?(view, "#plan-card-1[data-state='revised']")
      assert has_element?(view, "#plan-card-1 [data-qa='plan_card_revised']", "Revised since you reviewed it.")
      assert has_element?(view, "#plan-card-1 [data-qa='plan_card_reviewed'][aria-pressed='false']")
      assert has_element?(view, "#plan-card-1", "Refuses unless idle.")
      assert has_element?(view, "#plan-card-4[data-state='reviewed']")
      refute has_element?(view, "#plan-card-4 [data-qa='plan_card_revised']")
      assert has_element?(view, "#plan-reviewed-count", "1 of 5 reviewed")
      assert has_element?(view, "#plan-group-pipeline [data-qa='plan_group_reviewed']", "0 of 3 reviewed")

      # Marking it again reads the revision as reviewed.
      view |> element("#plan-card-1 [data-qa='plan_card_reviewed']") |> render_click()
      assert has_element?(view, "#plan-card-1[data-state='reviewed']")
      assert has_element?(view, "#plan-reviewed-count", "2 of 5 reviewed")
    end

    test "a reviewed card keeps the reader's comments and an open box under its header, each naming its line", %{
      conn: conn,
      task: task
    } do
      assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}?item=plan")

      view |> element("#plan-sheet button[aria-label='Comment on File 1, paragraph 1']") |> render_click()
      view |> form("#plan-sheet [data-qa='document_comment_form']", %{"body" => "Idle how?"}) |> render_submit()
      view |> element("#plan-sheet button[aria-label='Comment on File 1, signature line 1']") |> render_click()

      view |> element("#plan-card-1 [data-qa='plan_card_reviewed']") |> render_click()

      refute has_element?(view, "#plan-card-1", "Refuses unless the task is at :review and idle.")
      assert has_element?(view, "#plan-card-1 [data-qa='document_comment']", "Idle how?")
      assert has_element?(view, "#plan-card-1 [data-qa='document_comment_line']", "File 1, paragraph 1")
      assert has_element?(view, "#plan-card-1 [data-qa='document_comment_form']")
      assert has_element?(view, "#plan-card-1 [data-qa='document_comment_box_line']", "File 1, signature line 1")

      # Its path still takes a comment.
      view |> element("#plan-card-1 button[aria-label='Comment on File 1']") |> render_click()
      view |> form("#plan-card-1 [data-qa='document_comment_form']", %{"body" => "Rename it."}) |> render_submit()
      assert has_element?(view, "#plan-card-1 [data-qa='document_comment']", "Rename it.")
    end
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
