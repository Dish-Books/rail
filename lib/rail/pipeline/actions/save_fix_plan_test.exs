defmodule Rail.Pipeline.Actions.SaveFixPlanTest do
  use Rail.DataCase, async: true

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Finding
  alias Rail.Pipeline.Schemas.FixPlan
  alias Rail.Pipeline.Schemas.Task

  @plan "Guard it.\n\n### What changes\n\n#### `nil-crash`\n\nGuard nil.\n\n#### Comment 1\n\nKept.\n\n" <>
          "### File-level changes\n\n- `lib/a.ex`: guards nil. For `nil-crash` and comment 1.\n\n### Verification\n\nRun it."

  setup do
    scratch = Path.join(System.tmp_dir!(), "save_fix_plan_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(scratch) end)
    task = %Task{id: "tsk_save_fix_plan", stage: :review, scratch_path: scratch, issue: %Issue{identifier: "SFP-1"}}
    path = Path.join([scratch, "fix_plans", "SFP-1.json"])

    # As a Send leaves it: what it sent, and no plan yet.
    File.mkdir_p!(Path.dirname(path))

    File.write!(
      path,
      Jason.encode!(%{
        round: 1,
        findings: [%{key: "nil-crash", title: "Nil crashes"}],
        comments: [%{number: 1, kind: "diff", place: "a.ex:3", text: "Keep it."}]
      })
    )

    %{task: task, path: path}
  end

  test "a due plan saves as the next version covering what was sent, and a second save replaces it, each broadcast",
       %{task: task} do
    Phoenix.PubSub.subscribe(Rail.PubSub, "outputs:#{task.id}")

    assert {:ok, %FixPlan{version: 1, covered_keys: ["nil-crash"], covered_comments: 1}} =
             Pipeline.save_fix_plan(task, %{"plan" => @plan})

    assert_received {:output_saved, "tsk_save_fix_plan"}

    revised = String.replace(@plan, "Guard nil.", "Guard nil at the caller.")
    assert {:ok, %FixPlan{version: 2}} = Pipeline.save_fix_plan(task, %{"plan" => revised})
    assert_received {:output_saved, "tsk_save_fix_plan"}
    assert %FixPlan{version: 2, plan: ^revised} = Pipeline.read_fix_plan(task)
  end

  test "after a Send that changed rulings, a revised plan covering the new snapshot is approvable", %{
    task: task,
    path: path
  } do
    {:ok, _saved} = Pipeline.save_fix_plan(task, %{"plan" => @plan})
    # The Send dropped nil-crash and added a-nit.
    fix_plan = path |> File.read!() |> Jason.decode!()

    File.write!(path, Jason.encode!(%{fix_plan | "findings" => [%{key: "a-nit", title: "A nit"}]}))

    findings = [%Finding{key: "nil-crash", decision: :skip}, %Finding{key: "a-nit", decision: :fix}]
    assert FixPlan.state(Pipeline.read_fix_plan(task), task, findings) == :revising

    revised = String.replace(@plan, "`nil-crash`", "`a-nit`")
    assert {:ok, %FixPlan{version: 2} = saved} = Pipeline.save_fix_plan(task, %{"plan" => revised})
    assert FixPlan.state(saved, task, findings) == :waiting
  end

  test "a plan that leaves out what was sent is refused and the file stays as it was", %{task: task, path: path} do
    before = File.read!(path)

    assert {:error, %Ecto.Changeset{} = changeset} =
             Pipeline.save_fix_plan(task, %{"plan" => String.replace(@plan, "#### Comment 1\n\nKept.\n\n", "")})

    assert %{plan: ["leaves out comment 1" <> _rest]} = errors_on(changeset)
    assert File.read!(path) == before
  end

  test "a save with no plan due, as on a first round or a CI resume, or after approval, is refused", %{
    task: task,
    path: path
  } do
    {:ok, _saved} = Pipeline.save_fix_plan(task, %{"plan" => @plan})
    approved = path |> File.read!() |> Jason.decode!() |> Map.put("approved_at", "2026-10-12T16:58:00Z")
    File.write!(path, Jason.encode!(approved))

    assert {:error, :no_fix_plan} = Pipeline.save_fix_plan(task, %{"plan" => @plan})

    File.rm!(path)
    assert {:error, :no_fix_plan} = Pipeline.save_fix_plan(task, %{"plan" => @plan})
  end

  test "a plan says whether its round's screens are shot again and a demo recorded", %{task: task} do
    assert {:ok, %FixPlan{retake_screens: false, record_demo: false}} = Pipeline.save_fix_plan(task, %{"plan" => @plan})

    assert {:ok, %FixPlan{retake_screens: true, record_demo: true}} =
             Pipeline.save_fix_plan(task, %{"plan" => @plan, "retake_screens" => true, "record_demo" => true})

    assert %FixPlan{retake_screens: true, record_demo: true} = Pipeline.read_fix_plan(task)
  end

  # A changed ticket is said where the person approving reads it, before anything is approved on it.
  test "a plan that changes the ticket says so under Changes to the plan, or is refused", %{task: task} do
    assert {:error, changeset} = Pipeline.save_fix_plan(task, %{"plan" => @plan, "description" => "Filter by tag."})

    assert %{plan: ["changes the ticket or the design, so it opens with a `### Changes to the plan` section" <> _rest]} =
             errors_on(changeset)

    amended = "### Changes to the plan\n\n- Criteria: vendor becomes tag, as Ada asked.\n\n" <> @plan

    assert {:ok, %FixPlan{title: "Filter by tag", description: "Filter by tag."}} =
             Pipeline.save_fix_plan(task, %{
               "plan" => amended,
               "title" => "Filter by tag",
               "description" => "Filter by tag."
             })

    assert %FixPlan{title: "Filter by tag", description: "Filter by tag."} = Pipeline.read_fix_plan(task)
  end

  test "a plan that changed the design says so under Changes to the plan, or is refused", %{task: task} do
    assert {:error, changeset} = Pipeline.save_fix_plan(task, %{"plan" => @plan, "design_changed" => true})
    assert %{plan: ["changes the ticket or the design" <> _rest]} = errors_on(changeset)

    amended = "### Changes to the plan\n\n- Design: chips become a menu, as Ada asked.\n\n" <> @plan

    assert {:ok, %FixPlan{design_changed: true}} =
             Pipeline.save_fix_plan(task, %{"plan" => amended, "design_changed" => true})
  end
end
