defmodule RailWeb.Live.PlanStageTest do
  use RailWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Rail.Git
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

    child = fn number, title, estimate, builds_on ->
      %{
        "title" => title,
        "ticket" => "#{title} for each branch.\n\nMore detail.\n\n## Acceptance criteria\n\n* First\n* Second\n",
        "estimate" => estimate,
        "plan" => """
        ## Implementation plan

        ### Approach

        Part #{number}.

        ### Decisions

        - Decision: one module changes.

        ### Changes

        #### `lib/rail/part_#{number}.ex`

        Does part #{number}.

        ```elixir
        def part(x)
        ```

        #### `lib/rail/part_#{number}_more.ex`

        And the rest.

        ### Acceptance criteria

        - 1: `lib/rail/part_#{number}.ex`, `lib/rail/part_#{number}_test.exs`

        ### Verification

        - Part #{number} works.
        """,
        "builds_on" => builds_on
      }
    end

    %{conn: log_in_user(conn, user), user: user, task: task, run: run, child: child}
  end

  test "an approved plan reads as approved, its conversation readable but closed", %{
    conn: conn,
    user: user,
    task: task,
    run: run,
    child: child
  } do
    Pipeline.append_run_events(run.id, nil, ["[human:#{user.id}] Split the export from the import."])

    {:ok, _split} = Pipeline.save_split(task, %{"children" => [child.(1, "One", 1, []), child.(2, "Two", 1, [1])]})
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

  test "with no split the page has no Split section, only the ticket, the design and the plan", %{
    conn: conn,
    task: task
  } do
    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    assert has_element?(view, "#plan-section-ticket")
    assert has_element?(view, "#plan-section-design")
    assert has_element?(view, "#plan-section-plan #plan-plan")
    refute has_element?(view, "#plan-section-split")
    refute has_element?(view, "#plan-split-none")
  end

  test "a saved split lays its children out in the rounds they start in", %{
    conn: conn,
    task: task,
    child: child
  } do
    {:ok, _split} =
      Pipeline.save_split(task, %{
        "children" => [
          child.(1, "Deploys start", 3, []),
          child.(2, "QA drives them", 2, [1]),
          child.(3, "Demo records them", 2, [1]),
          child.(4, "Settings", 1, [2, 3])
        ]
      })

    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    assert has_element?(view, "#plan-section-split #plan-split")
    assert has_element?(view, "#plan-section-split-status", "4 children · 8 points")
    assert has_element?(view, "#plan-split", "Split into 4 children")
    assert has_element?(view, "#plan-split", "8 points · 3 rounds")

    assert ["Starts at once", "After 1", "After 2 and 3"] ==
             view
             |> render()
             |> Floki.parse_document!()
             |> Floki.find("[data-qa='plan_split_round'] > p")
             |> Enum.map(&String.trim(Floki.text(&1)))

    assert has_element?(view, "#plan-split-child-2", "QA drives them")
    assert has_element?(view, "#plan-split-child-2", "QA drives them for each branch.")
    refute has_element?(view, "#plan-split-child-2", "More detail.")
    assert has_element?(view, "#plan-split-child-2", "2 criteria")
    assert has_element?(view, "#plan-split-child-2", "lib/rail/part_2.ex")
    assert has_element?(view, "#plan-split-child-2", "+ 1 more")
  end

  test "a card opens to its child's whole ticket and part of the plan, and closes again", %{
    conn: conn,
    task: task,
    child: child
  } do
    {:ok, _split} = Pipeline.save_split(task, %{"children" => [child.(1, "One", 1, []), child.(2, "Two", 2, [1])]})
    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
    refute has_element?(view, "#plan-split-child-detail")

    view |> element("#plan-split-child-2-open") |> render_click()

    assert has_element?(view, "#plan-split-child-2-open[aria-expanded='true']")
    assert has_element?(view, "#plan-split-child-detail", "Two for each branch.")
    assert has_element?(view, "#plan-split-child-detail", "More detail.")
    assert has_element?(view, "#plan-split-child-detail li", "Second")
    assert has_element?(view, "#plan-split-child-detail #split-part-sheet", "lib/rail/part_2_more.ex")

    view |> element("#plan-split-child-2-open") |> render_click()
    refute has_element?(view, "#plan-split-child-detail")
  end

  test "a part opens as a sheet of its child's own criteria, its ids named by the child's number", %{
    conn: conn,
    task: task,
    child: child
  } do
    {:ok, _split} = Pipeline.save_split(task, %{"children" => [child.(1, "One", 1, []), child.(2, "Two", 1, [])]})
    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    view |> element("#plan-split-child-2-open") |> render_click()

    assert has_element?(view, "#plan-split-child-detail #split-part-2-group-part-2 #split-part-2-card-1")
    assert has_element?(view, "#plan-split-child-detail [data-qa='plan_criterion']", "First")
    assert has_element?(view, "#plan-split-child-detail [data-qa='plan_criterion']", "part_2_test.exs")
    assert has_element?(view, "#plan-split-child-detail [data-qa='plan_criterion']", "Not covered")
  end

  test "a part saved before cards still names its first file on its card and opens as markdown", %{
    conn: conn,
    task: task,
    child: child
  } do
    {:ok, _split} = Pipeline.save_split(task, %{"children" => [child.(1, "One", 1, []), child.(2, "Two", 1, [])]})
    path = Path.join([task.scratch_path, "splits", "PST-1.json"])
    %{"children" => [first, second]} = path |> File.read!() |> Jason.decode!()

    old =
      "## Implementation plan\n\n### Approach\n\nOld.\n\nNo diagrams: one module.\n\n" <>
        "### File-level changes\n\n- `lib/rail/old.ex`: does it.\n- `lib/rail/older.ex`: and more.\n\n" <>
        "### Verification\n\n- Works."

    bare = "## Implementation plan\n\nNothing laid out."
    File.write!(path, Jason.encode!(%{"children" => [%{first | "plan" => bare}, %{second | "plan" => old}]}))

    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
    assert has_element?(view, "#plan-split-child-2", "lib/rail/old.ex")
    assert has_element?(view, "#plan-split-child-2", "+ 1 more")
    refute has_element?(view, "#plan-split-child-1", "more")

    view |> element("#plan-split-child-2-open") |> render_click()
    refute has_element?(view, "#plan-split-child-detail #split-part-sheet")
    assert has_element?(view, "#plan-split-child-detail h3", "File-level changes")
    assert has_element?(view, "#plan-split-child-detail li", "and more.")
  end

  test "each card says what its own child builds on, which its lane alone would not", %{
    conn: conn,
    task: task,
    child: child
  } do
    {:ok, _split} =
      Pipeline.save_split(task, %{
        "children" => [
          child.(1, "One", 1, []),
          child.(2, "Two", 1, []),
          child.(3, "Three", 1, [1]),
          child.(4, "Four", 1, [2])
        ]
      })

    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    assert has_element?(view, "[data-qa='plan_split_round']", "After 1 and 2")
    assert has_element?(view, "#plan-split-child-1-order", "starts at once")
    assert view |> element("#plan-split-child-3-order") |> render() =~ ~r/>\s*after 1\s*</
    assert view |> element("#plan-split-child-4-order") |> render() =~ ~r/>\s*after 2\s*</
  end

  test "a new save shows in the lanes without a reload", %{conn: conn, task: task, child: child} do
    {:ok, _split} = Pipeline.save_split(task, %{"children" => [child.(1, "One", 1, []), child.(2, "Two", 1, [])]})
    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
    assert has_element?(view, "#plan-split", "1 round")

    {:ok, _split} =
      Pipeline.save_split(task, %{
        "children" => [
          child.(1, "One", 1, []),
          child.(2, "Two", 1, [1]),
          child.(3, "Three", nil, [])
        ]
      })

    # The save reaches the pane as an update the page sends itself, after the first render it is asked for.
    _settled = render(view)
    assert has_element?(view, "#plan-split", "Split into 3 children")
    assert has_element?(view, "#plan-split", "2 rounds")
    assert has_element?(view, "#plan-split-child-3", "Three")
    assert has_element?(view, "#plan-section-split-status", "3 children · 2 points")

    view |> element("#plan-split-child-3-open") |> render_click()
    assert has_element?(view, "#plan-split-child-detail", "lib/rail/part_3_more.ex")
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

        part = %{
          number: number,
          title: "A part",
          ticket: "Its criteria.",
          estimate: 1,
          builds_on: builds_on,
          builds_screen: false,
          plan: "## Implementation plan\n\nPart #{number}."
        }

        {:ok, child} = Pipeline.create_child_task(parent, issue, part)
        Repo.preload(child, [:issue, :project])
      end

    on_exit(fn -> File.rm_rf(parent.scratch_path) end)
    Repo.update_all(from(r in Round, where: r.task_id == ^third.id), set: [plan: sheet_plan()])

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
