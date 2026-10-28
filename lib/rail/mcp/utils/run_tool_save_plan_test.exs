defmodule Rail.Mcp.Utils.RunToolSavePlanTest do
  use Rail.DataCase, async: true

  import Rail.Mcp.Utils.RunToolSavePlan

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Round

  # The smallest plan the structure allows: one decision, one card and one criterion, and no data changes.
  @plan """
  ## Implementation plan

  ### Approach

  Extend the module.

  ### Decisions

  - Decision: one module changes.

  ### Changes

  #### `lib/rail.ex`

  Extends the module.

  ### Acceptance criteria

  - 1: `lib/rail.ex`

  ### Verification

  - `lib/rail_test.exs`: covers the extension.
  """

  setup %{project: project} do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_rt_plan_1", "identifier" => "RTP-1", "title" => "Tool Plan"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Tool Plan"})
    {:ok, task} = Pipeline.create_task(issue, :plan)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    %{task: task, scratch: task.scratch_path}
  end

  test "a save of the ticket alone says no implementation plan is saved yet", %{task: task} do
    assert {:ok, "Ticket saved: Usage charts. No implementation plan is saved yet." <> _rest} =
             run_tool_save_plan(task, %{"title" => "Usage charts", "description" => "Show usage.", "unknown" => "x"}, [])

    assert %Round{ticket: %{title: "Usage charts"}, plan: nil} = Pipeline.read_plan(task)
  end

  test "a save with a plan and no option says it names none yet", %{task: task} do
    assert {:ok, "Ticket saved: Usage charts. Plan saved, written for no design option yet." <> _rest} =
             run_tool_save_plan(task, %{"title" => "Usage charts", "description" => "Show usage.", "plan" => @plan}, [])

    assert %Round{design: nil} = Pipeline.read_plan(task)
  end

  test "a save for a saved option passes the key through and names the option", %{task: task, scratch: scratch} do
    File.mkdir_p!(Path.join(scratch, "design"))

    File.write!(
      Path.join(scratch, "design/manifest.json"),
      ~s({"options": [{"key": "rows", "title": "Charts in the row"}]})
    )

    assert {:ok, "Ticket saved: Usage charts. Plan saved for Charts in the row (rows)." <> _rest} =
             run_tool_save_plan(
               task,
               %{"title" => "Usage charts", "description" => "Show usage.", "plan" => @plan, "design" => "rows"},
               []
             )
  end

  test "a refusal is passed back as the changeset naming the field", %{task: task} do
    assert {:error, %Ecto.Changeset{valid?: false}} = run_tool_save_plan(task, %{}, [])

    assert {:error, %Ecto.Changeset{errors: [design: _no_options]}} =
             run_tool_save_plan(task, %{"plan" => @plan, "design" => "rows"}, [])
  end

  test "a save after approval is refused, saying the plan no longer changes", %{task: task} do
    {:ok, round} = Pipeline.save_plan(task, %{title: "Usage charts", description: "Show usage.", plan: @plan})
    round |> Round.approve_changeset(nil) |> Repo.update!()

    assert {:refused, "Nothing saved: the plan is approved, so it no longer changes."} =
             run_tool_save_plan(task, %{"title" => "Something else"}, [])
  end

  test "a part whose step the task's workflow turned off is refused, saying the step is off", %{task: task} do
    issue =
      Repo.preload(task, :issue).issue
      |> Ecto.Changeset.change(skipped_steps: [:product, :architect, :demo])
      |> Repo.update!()

    task = %{task | issue: issue}

    assert {:refused, "Nothing saved: Product is off for this task, so the issue is the ticket." <> _rest} =
             run_tool_save_plan(task, %{"title" => "Usage charts"}, [])

    assert {:refused, "Nothing saved: Architect is off for this task" <> _rest} =
             run_tool_save_plan(task, %{"plan" => @plan}, [])

    assert {:refused, "Nothing saved: the demo is off for this task" <> _rest} =
             run_tool_save_plan(task, %{"record_demo" => true}, [])
  end
end
