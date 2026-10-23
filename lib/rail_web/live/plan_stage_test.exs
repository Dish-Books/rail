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
    assert has_element?(view, "#child-plan #plan-sheet")
  end
end
