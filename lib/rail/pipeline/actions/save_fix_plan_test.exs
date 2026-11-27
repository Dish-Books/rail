defmodule Rail.Pipeline.Actions.SaveFixPlanTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Finding
  alias Rail.Pipeline.Schemas.FixPlan
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Roles

  @plan "Guard it.\n\n### What changes\n\n#### `nil-crash`\n\nGuard nil.\n\n#### Comment 1\n\nKept.\n\n" <>
          "### File-level changes\n\n#### `lib/a.ex`\n\nGuards nil. For `nil-crash` and comment 1.\n\n```elixir sketch\ndef go, do: :ok\n```\n\n### Verification\n\nRun it."

  setup do
    scratch = Path.join(System.tmp_dir!(), "save_fix_plan_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(scratch) end)
    # No worktree is on disk, so the branch is not checked against the default branch.
    task = %Task{
      id: "tsk_save_fix_plan",
      stage: :review,
      scratch_path: scratch,
      worktree_path: Path.join(scratch, "worktree"),
      issue: %Issue{identifier: "SFP-1"}
    }

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

  # A person can ask for a change at Finalize, once nothing is left to fix.
  test "once a review is saved a plan is due unasked, even with nothing to fix", %{task: task, path: path} do
    File.rm!(path)
    reviews = Path.join([task.scratch_path, "reviews", "SFP-1.json"])
    File.mkdir_p!(Path.dirname(reviews))
    File.write!(reviews, ~s({"passes": [{"round": 1, "saved_at": "2026-10-14T10:00:00Z", "head": "abc"}]}))

    plan =
      "### Changes to the plan\n\n- Criterion 1: a dot.\n\n### What changes\n\n#### Changes to the plan\n\n" <>
        "The heading takes a dot.\n\n### File-level changes\n\n#### `lib/a.ex`\n\nThe dot. For the changes to the plan.\n\n```elixir sketch\ndef go, do: :ok\n```"

    assert {:ok, %FixPlan{version: 1, round: 1, head: "abc", findings: [], covered_keys: []}} =
             Pipeline.save_fix_plan(%{task | stage: :finalize}, %{"plan" => plan, "description" => "A dot."})
  end

  # Approving it would start an engineer on nothing, and while it waited Finish review was hidden.
  test "an unasked plan with nothing to fix and no change to the ticket or design is refused", %{task: task, path: path} do
    File.rm!(path)
    reviews = Path.join([task.scratch_path, "reviews", "SFP-1.json"])
    File.mkdir_p!(Path.dirname(reviews))
    File.write!(reviews, ~s({"passes": [{"round": 1, "saved_at": "2026-10-14T10:00:00Z", "head": "abc"}]}))

    nothing = "Nothing to fix. The task is ready to finalize.\n\n### What changes"

    assert {:error, :nothing_to_fix} = Pipeline.save_fix_plan(task, %{"plan" => nothing, "design_changed" => false})
    refute File.exists?(path)
  end

  test "a plan says whether its round's demo is recorded", %{task: task} do
    assert {:ok, %FixPlan{record_demo: false}} = Pipeline.save_fix_plan(task, %{"plan" => @plan})

    assert {:ok, %FixPlan{record_demo: true}} =
             Pipeline.save_fix_plan(task, %{"plan" => @plan, "record_demo" => true})

    assert %FixPlan{record_demo: true} = Pipeline.read_fix_plan(task)
  end

  test "a task whose workflow turned the demo off refuses a plan asking for one, and saves one that does not", %{
    task: task
  } do
    task = %{task | issue: %{task.issue | skipped_steps: [:demo]}}

    assert {:error, {:step_off, :demo}} = Pipeline.save_fix_plan(task, %{"plan" => @plan, "record_demo" => true})
    assert %FixPlan{plan: nil} = Pipeline.read_fix_plan(task)
    assert {:ok, %FixPlan{record_demo: false}} = Pipeline.save_fix_plan(task, %{"plan" => @plan})
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

  describe "a change asked for in the conversation" do
    @asked "Fold the helper in, as Ada asked.\n\n### What changes\n\n#### Changes to the plan\n\nAda asked to fold " <>
             "`check_ids` into `check`.\n\n### File-level changes\n\n#### `lib/a.ex`\n\nFolds it in. For the changes " <>
             "to the plan.\n\n```elixir sketch\ndef check(ids, opts), do: :ok\n```"

    setup %{project: project} do
      {:ok, role} = Roles.get_role(project_id: project.id, stage: :review_lead)
      {:ok, issue} = Issues.create_issue(system_scope(), project, %{title: "Issue", description: "Asked in chat"})
      {:ok, task} = Pipeline.create_task(issue, :finalize)
      task = Repo.preload(task, :issue)
      on_exit(fn -> File.rm_rf(task.scratch_path) end)

      {:ok, run} =
        Pipeline.create_run(%{task_id: task.id, role_id: role.id, status: :finished, started_at: DateTime.utc_now()})

      reviews = Path.join([task.scratch_path, "reviews", "#{issue.identifier}.json"])
      File.mkdir_p!(Path.dirname(reviews))
      saved_at = DateTime.shift(DateTime.utc_now(), minute: -1)
      File.write!(reviews, Jason.encode!(%{passes: [%{round: 1, saved_at: saved_at, head: "abc"}]}))

      %{task: task, run: run, saved_at: saved_at}
    end

    test "a person's message to the Review lead since the review makes a plan due", %{task: task, run: run} do
      assert {:error, :nothing_to_fix} = Pipeline.save_fix_plan(task, %{"plan" => @asked})

      # Rail's own line on a person's behalf asks for nothing.
      Pipeline.append_run_events(run.id, nil, ["[human] Finish review: nothing was ruled Fix."])
      assert {:error, :nothing_to_fix} = Pipeline.save_fix_plan(task, %{"plan" => @asked})

      Pipeline.append_run_events(run.id, nil, ["[human:usr_ada] fold check_ids into check"])

      assert {:ok, %FixPlan{version: 1, round: 1, findings: [], comments: []}} =
               Pipeline.save_fix_plan(task, %{"plan" => @asked})
    end

    test "the plan says what was asked under Changes to the plan, or is refused", %{task: task, run: run} do
      Pipeline.append_run_events(run.id, nil, ["[human:usr_ada] fold check_ids into check"])
      unnamed = String.replace(@asked, "#### Changes to the plan\n\n", "")

      assert {:error, %Ecto.Changeset{} = changeset} = Pipeline.save_fix_plan(task, %{"plan" => unnamed})
      assert %{plan: ["covers no finding or comment, so the change asked for" <> _rest]} = errors_on(changeset)
    end

    test "a message from before the review, or before the last plan's approval, is that round's", %{
      task: task,
      run: run,
      saved_at: saved_at
    } do
      Pipeline.append_run_events(run.id, nil, ["[human:usr_ada] fold check_ids into check"])

      reviews = Path.join([task.scratch_path, "reviews", "#{task.issue.identifier}.json"])
      later = DateTime.shift(DateTime.utc_now(), minute: 1)
      File.write!(reviews, Jason.encode!(%{passes: [%{round: 1, saved_at: later, head: "abc"}]}))
      assert {:error, :nothing_to_fix} = Pipeline.save_fix_plan(task, %{"plan" => @asked})

      File.write!(reviews, Jason.encode!(%{passes: [%{round: 1, saved_at: saved_at, head: "abc"}]}))
      {:ok, _saved} = Pipeline.save_fix_plan(task, %{"plan" => @asked})
      plans = Path.join([task.scratch_path, "fix_plans", "#{task.issue.identifier}.json"])
      approved = plans |> File.read!() |> Jason.decode!() |> Map.put("approved_at", later)
      File.write!(plans, Jason.encode!(approved))

      assert {:error, :nothing_to_fix} = Pipeline.save_fix_plan(task, %{"plan" => @asked})
    end
  end
end
