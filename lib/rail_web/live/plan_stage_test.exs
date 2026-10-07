defmodule RailWeb.Live.PlanStageTest do
  use RailWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.ImplementationPlan
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Scope
  alias Rail.Users

  # The smallest plan the structure allows: no diagrams, so Approach says why, and no Program design.
  @plan """
  ## Implementation plan

  ### Approach

  All of it.

  No diagrams: one module changes.

  ### File-level changes

  - `lib/rail.ex`: does all of it.

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

    {:ok, _run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :finished,
        stage_outcome: :done,
        conversation_id: "sess_plan_stage",
        started_at: DateTime.utc_now()
      })

    {:ok, _ticket} = Pipeline.save_ticket(task, %{title: "Previews", description: "## Acceptance criteria\n\n- One\n"})
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

        No diagrams: one module changes.

        ### File-level changes

        - `lib/rail/part_#{number}.ex`: does part #{number}.
        - `lib/rail/part_#{number}_more.ex`: and the rest.

        ### Program design

        #### `Rail.Part#{number}` new
        `lib/rail/part_#{number}.ex`
        ```elixir
        def part(x)
        ```

        ### Verification

        - `lib/rail/part_#{number}_test.exs`: covers part #{number}.
        """,
        "builds_on" => builds_on
      }
    end

    %{conn: log_in_user(conn, user), task: task, child: child}
  end

  test "an approved plan reads as approved, with no conversation left to change it", %{
    conn: conn,
    task: task,
    child: child
  } do
    {:ok, _split} = Pipeline.save_split(task, %{"children" => [child.(1, "One", 1, []), child.(2, "Two", 1, [1])]})
    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
    assert has_element?(view, "#task-conversation-column")

    {:ok, task} = Pipeline.update_task(task, %{stage: :split})
    Repo.insert!(%ImplementationPlan{task_id: task.id, content: @plan, captured_at: DateTime.utc_now()})
    {:ok, plan_role} = Roles.get_role(project_id: task.project_id, stage: :plan)

    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}?tab=#{plan_role.id}")
    assert has_element?(view, "#plan-approved", "Plan approved")
    refute has_element?(view, "#task-conversation-column")
  end

  test "with no split the Split item reads Not split and Approve shows as today", %{conn: conn, task: task} do
    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    assert has_element?(view, "#plan-item-split-status", "Not split: one task")
    assert has_element?(view, "#approve-plan")

    view |> element("#plan-item-split") |> render_click()
    assert has_element?(view, "#plan-split-none", "Not split")
  end

  test "a saved split lays its children out in the rounds they start in, and Approve shows", %{
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

    assert has_element?(view, "#plan-item-split[aria-current='true']")
    assert has_element?(view, "#plan-item-split-status", "4 children · 8 points")
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
    assert has_element?(view, "#approve-plan")
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
    assert has_element?(view, "#plan-split-child-detail #plan-sheet", "lib/rail/part_2_more.ex")

    view |> element("#plan-split-child-2-open") |> render_click()
    refute has_element?(view, "#plan-split-child-detail")
  end

  test "a prose-only part with No diagrams: on its own renders its card and opens as a sheet", %{
    conn: conn,
    task: task,
    child: child
  } do
    prose = %{
      "title" => "Prompt",
      "ticket" => "The prompt says more.",
      "plan" => """
      ## Implementation plan

      ### Approach

      Only the architect prompt changes.

      No diagrams: nothing but prose changes.

      ### File-level changes

      - `.rail/prompts/architect.md`: says more.

      ### Verification

      - `lib/rail/pipeline/utils/plan_subagents_test.exs`: still passes.
      """
    }

    {:ok, _split} = Pipeline.save_split(task, %{"children" => [child.(1, "One", 1, []), prose]})
    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    assert has_element?(view, "#plan-split-child-1", "One")
    assert has_element?(view, "#plan-split-child-2", ".rail/prompts/architect.md")

    view |> element("#plan-split-child-2-open") |> render_click()
    assert has_element?(view, "#plan-split-child-detail #plan-sheet", ".rail/prompts/architect.md")
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

    assert has_element?(view, "#plan-split", "Split into 3 children")
    assert has_element?(view, "#plan-split", "2 rounds")
    assert has_element?(view, "#plan-split-child-3", "Three")
    assert has_element?(view, "#plan-item-split-status", "3 children · 2 points")

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
        part = %{number: number, builds_on: builds_on, plan: "## Implementation plan\n\nPart #{number}."}
        {:ok, child} = Pipeline.create_child_task(parent, issue, part)
        Repo.preload(child, [:issue, :project])
      end

    on_exit(fn -> File.rm_rf(parent.scratch_path) end)
    Repo.update_all(from(p in ImplementationPlan, where: p.task_id == ^third.id), set: [content: sheet_plan()])

    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{parent.id}?child=PST-13")

    assert has_element?(view, "#child-plan-waiting", "Starts when PST-11 and PST-12 merge.")
    assert has_element?(view, "#child-plan-approved", "Approved in PST-10 · part 3 of 3")
    assert has_element?(view, "#child-plan #plan-sheet")
  end
end
