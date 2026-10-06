defmodule Rail.Pipeline.Actions.SavePlanTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.ImplementationPlan
  alias Rail.Pipeline.Schemas.Task

  setup do
    scratch = Path.join(System.tmp_dir!(), "save_plan_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(scratch) end)

    task = %Task{
      id: "tsk_save_plan_#{System.unique_integer([:positive])}",
      scratch_path: scratch,
      issue: %Issue{identifier: "SVP-1"}
    }

    Phoenix.PubSub.subscribe(Rail.PubSub, "outputs:#{task.id}")

    options = [%{"key" => "rows", "title" => "Charts in the row"}, %{"key" => "panel", "title" => "Usage panel"}]
    File.mkdir_p!(Path.join(scratch, "design"))

    write_options = fn ->
      File.write!(Path.join(scratch, "design/manifest.json"), Jason.encode!(%{"options" => options}))
    end

    %{task: task, scratch: scratch, write_options: write_options}
  end

  test "a plan under the heading is written where read_plan reads it, and broadcast", %{task: %{id: task_id} = task} do
    assert {:ok, %{content: "## Implementation plan\n\nExtend the module.\n", design: nil}} =
             Pipeline.save_plan(task, %{plan: "## Implementation plan\n\nExtend the module.\n"})

    assert %{content: "## Implementation plan\n\nExtend the module.\n", saved_at: %DateTime{}} = Pipeline.read_plan(task)
    assert_received {:output_saved, ^task_id}
  end

  test "a blank plan, or one without the heading, is refused and leaves the earlier plan", %{task: task} do
    {:ok, _first} = Pipeline.save_plan(task, %{plan: "## Implementation plan\n\nFirst."})

    assert {:error, blank} = Pipeline.save_plan(task, %{plan: "   "})
    assert %{plan: ["can't be blank"]} = errors_on(blank)

    assert {:error, unheaded} = Pipeline.save_plan(task, %{plan: "# Plan\n\nSecond."})
    assert %{plan: ["must open with the `## Implementation plan` heading"]} = errors_on(unheaded)

    assert {:error, listed} = Pipeline.save_plan(task, %{plan: ["## Implementation plan"]})
    assert %{plan: ["is invalid"]} = errors_on(listed)

    assert %{content: "## Implementation plan\n\nFirst.\n"} = Pipeline.read_plan(task)
  end

  test "a second save replaces the first", %{task: task} do
    {:ok, _first} = Pipeline.save_plan(task, %{plan: "## Implementation plan\n\nFirst."})
    {:ok, _second} = Pipeline.save_plan(task, %{plan: "## Implementation plan\n\nSecond."})

    assert %{content: "## Implementation plan\n\nSecond.\n"} = Pipeline.read_plan(task)
  end

  test "a plan saved for an option keeps its title after the pick deletes the option", %{
    task: task,
    scratch: scratch,
    write_options: write_options
  } do
    write_options.()

    assert {:ok, %{design: %{key: "panel", title: "Usage panel"}}} =
             Pipeline.save_plan(task, %{"plan" => "## Implementation plan\n\nPanel.", "design" => "panel"})

    File.write!(
      Path.join(scratch, "design/manifest.json"),
      ~s({"options": [{"key": "rows", "title": "Charts in the row"}]})
    )

    File.write!(Path.join(scratch, "design/picked"), "rows")

    assert %{design: %{key: "panel", title: "Usage panel"}} = Pipeline.read_plan(task)
  end

  test "a plan saved before the pick with no option names none, and a later save for none clears the option", %{
    task: task,
    write_options: write_options
  } do
    write_options.()

    assert {:ok, %{design: nil}} = Pipeline.save_plan(task, %{plan: "## Implementation plan\n\nOpen screen."})

    assert {:ok, %{design: %{key: "rows"}}} =
             Pipeline.save_plan(task, %{plan: "## Implementation plan\n\nRows.", design: "rows"})

    assert {:ok, %{design: nil}} = Pipeline.save_plan(task, %{plan: "## Implementation plan\n\nOpen again."})
    assert %{design: nil} = Pipeline.read_plan(task)
  end

  test "a key naming no option, or any key with no options, is refused and leaves the last good save", %{
    task: task,
    write_options: write_options
  } do
    assert {:error, no_options} = Pipeline.save_plan(task, %{plan: "## Implementation plan\n\nX.", design: "rows"})
    assert %{design: ["names an option, but no design options are saved; leave it out"]} = errors_on(no_options)

    write_options.()
    {:ok, _good} = Pipeline.save_plan(task, %{plan: "## Implementation plan\n\nGood.", design: "rows"})

    assert {:error, unknown} = Pipeline.save_plan(task, %{plan: "## Implementation plan\n\nBad.", design: "cards"})
    assert %{design: ["cards is not a saved design option; it is one of rows, panel"]} = errors_on(unknown)

    assert %{content: "## Implementation plan\n\nGood.\n", design: %{key: "rows"}} = Pipeline.read_plan(task)
  end

  describe "once the plan is approved" do
    setup %{project: project} do
      Req.Test.expect(Rail.Linear, fn conn ->
        Req.Test.json(conn, %{
          "data" => %{
            "issueCreate" => %{
              "success" => true,
              "issue" => %{"id" => "lin_save_plan_1", "identifier" => "SVP-2", "title" => "Save Plan"}
            }
          }
        })
      end)

      {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Save Plan"})
      {:ok, task} = Pipeline.create_task(issue, :plan)
      on_exit(fn -> File.rm_rf(task.scratch_path) end)

      approved_at = DateTime.shift(DateTime.utc_now(), minute: -1)

      approve = fn ->
        Repo.insert!(%ImplementationPlan{
          task_id: task.id,
          content: "## Implementation plan\n\nApproved.",
          captured_at: approved_at
        })
      end

      %{real_task: task, approve: approve, approved_at: approved_at}
    end

    test "a plan saved before approval leaves no approved plan", %{real_task: task} do
      {:ok, _plan} = Pipeline.save_plan(task, %{plan: "## Implementation plan\n\nDraft."})

      assert {:error, :not_found} = Pipeline.get_implementation_plan(task)
    end

    # Nothing is stubbed for Linear past the issue's creation, so any write to the issue would fail the test.
    test "a plan saved after approval replaces the approved one without touching the issue", %{
      real_task: task,
      approve: approve,
      approved_at: approved_at
    } do
      %{id: id} = approve.()
      {:ok, task} = Pipeline.update_task(task, %{stage: :engineer})

      {:ok, _plan} = Pipeline.save_plan(task, %{plan: "## Implementation plan\n\nRevised after approval."})

      assert {:ok,
              %ImplementationPlan{id: ^id, content: "## Implementation plan\n\nRevised after approval.", captured_at: at}} =
               Pipeline.get_implementation_plan(task)

      assert DateTime.after?(at, approved_at)
    end

    test "a plan saved after a return to Plan leaves the approved one as it was", %{real_task: task, approve: approve} do
      %{id: id} = approve.()

      {:ok, _plan} = Pipeline.save_plan(task, %{plan: "## Implementation plan\n\nBeing argued over."})

      assert {:ok, %ImplementationPlan{id: ^id, content: "## Implementation plan\n\nApproved."}} =
               Pipeline.get_implementation_plan(task)
    end
  end
end
