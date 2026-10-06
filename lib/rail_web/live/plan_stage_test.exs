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
    {:ok, _plan} = Pipeline.save_plan(task, %{plan: "## Implementation plan\n\nAll of it."})

    child = fn number, title, estimate, builds_on ->
      %{
        "title" => title,
        "ticket" => "#{title} for each branch.\n\nMore detail.\n\n## Acceptance criteria\n\n* First\n* Second\n",
        "estimate" => estimate,
        "plan" => """
        ## Implementation plan

        ### Approach

        Part #{number}.

        ### File-level changes

        - `lib/rail/part_#{number}.ex`: does part #{number}.
        - `lib/rail/part_#{number}_more.ex`: and the rest.

        ### Program design

        #### `Rail.Part#{number}` new
        `lib/rail/part_#{number}.ex`
        ```elixir
        def part(x)
        ```
        """,
        "builds_on" => builds_on
      }
    end

    %{conn: log_in_user(conn, user), task: task, child: child}
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

  test "a new save shows in the lanes without a reload", %{conn: conn, task: task, child: child} do
    {:ok, _split} = Pipeline.save_split(task, %{"children" => [child.(1, "One", 1, []), child.(2, "Two", 1, [])]})
    assert {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
    assert has_element?(view, "#plan-split", "1 round")

    {:ok, _split} =
      Pipeline.save_split(task, %{
        "children" => [
          child.(1, "One", 1, []),
          child.(2, "Two", 1, [1]),
          %{"title" => "Three", "ticket" => "Three.", "plan" => "## Implementation plan\n\nJust this."}
        ]
      })

    assert has_element?(view, "#plan-split", "Split into 3 children")
    assert has_element?(view, "#plan-split", "2 rounds")
    assert has_element?(view, "#plan-split-child-3", "Three")
    assert has_element?(view, "#plan-item-split-status", "3 children · 2 points")
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
