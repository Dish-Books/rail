defmodule Rail.Pipeline.Actions.ReadPlanTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Round

  @plan "## Implementation plan\n\n### Approach\n\nExtend it.\n\nNo diagrams: one module changes.\n\n### File-level changes\n\n- `lib/rail.ex`: extends it.\n\n### Verification\n\n- `lib/rail_test.exs`: covers it."

  setup %{project: project} do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_read_plan_1", "identifier" => "RDP-1", "title" => "Plans"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Plans"})
    {:ok, task} = Pipeline.create_task(issue, :plan)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    %{task: task}
  end

  test "returns the first round with the ticket, the plan, the option it is written for and when it was saved",
       %{task: task} do
    File.mkdir_p!(Path.join(task.scratch_path, "design"))

    File.write!(
      Path.join(task.scratch_path, "design/manifest.json"),
      Jason.encode!(%{"options" => [%{"key" => "rows", "title" => "Charts in the row"}]})
    )

    {:ok, _saved} = Pipeline.save_plan(task, %{title: "A ticket", description: "The body.", plan: @plan, design: "rows"})

    assert %Round{
             number: 1,
             plan: @plan,
             plan_saved_at: %DateTime{},
             approved_at: nil,
             ticket: %{title: "A ticket", description: "The body."},
             design: %{key: "rows", title: "Charts in the row"}
           } = Pipeline.read_plan(task)
  end

  test "an approved plan carries when it was approved", %{task: task} do
    {:ok, round} = Pipeline.save_plan(task, %{title: "A ticket", description: "The body.", plan: @plan})
    round |> Round.approve_changeset(nil) |> Repo.update!()

    assert %Round{plan: @plan, approved_at: %DateTime{}} = Pipeline.read_plan(task)
  end

  test "a later round is not the task's plan", %{task: task} do
    {:ok, _saved} = Pipeline.save_plan(task, %{title: "A ticket", description: "The body.", plan: @plan})
    {:ok, second} = Pipeline.create_round(task)
    {:ok, _planned} = Pipeline.save_round_plan(second, %{plan: "Fix the finding."})

    assert %Round{number: 1, plan: @plan} = Pipeline.read_plan(task)
  end

  test "a ticket saved before its plan has no plan yet, and nothing saved is no plan at all", %{task: task} do
    assert Pipeline.read_plan(task) == nil

    {:ok, _ticket} = Pipeline.save_plan(task, %{title: "A ticket", description: "The body."})

    assert %Round{plan: nil, ticket: %{title: "A ticket"}} = Pipeline.read_plan(task)
  end
end
