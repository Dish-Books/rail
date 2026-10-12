defmodule RailWeb.Utils.RoleStatusLabelTest do
  use Rail.DataCase, async: true

  import RailWeb.Utils.RoleStatusLabel

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Roles.Schemas.Role

  test "a role that has never run has not started" do
    assert role_status_label(%Role{stage: :plan}, nil, %Task{stage: :plan}) == "not started"
  end

  test "a run says what it is doing" do
    role = %Role{stage: :plan}
    task = %Task{stage: :plan}

    assert role_status_label(role, %Run{status: :running}, task) == "in progress"
    assert role_status_label(role, %Run{status: :blocked_on_input}, task) == "needs an answer"
    assert role_status_label(role, %Run{status: :finished, error: "boom"}, task) == "failed"
    assert role_status_label(role, %Run{status: :finished}, task) == "stopped"
    assert role_status_label(role, %Run{status: :waiting_for_resources}, task) == "waiting for resources"
    assert role_status_label(role, %Run{status: :waiting_for_usage}, task) == "waiting for usage"
  end

  test "the role for the stage the task sits at says what to go and read" do
    done = %Run{status: :finished, stage_outcome: :done}
    scratch = Path.join(System.tmp_dir!(), "role_status_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(scratch) end)
    plan_task = %Task{stage: :plan, scratch_path: scratch}

    assert role_status_label(%Role{stage: :plan}, done, plan_task) == "review the plan"
    assert role_status_label(%Role{stage: :review_lead}, done, %Task{stage: :review}) == "review"
    assert role_status_label(%Role{stage: :engineer}, done, %Task{stage: :engineer}) == "needs review"

    options = for key <- ["a", "b", "c"], do: %{"key" => key, "title" => String.upcase(key)}
    File.mkdir_p!(Path.join(scratch, "design"))
    File.write!(Path.join(scratch, "design/manifest.json"), Jason.encode!(%{"options" => options}))

    assert role_status_label(%Role{stage: :plan}, done, plan_task) == "pick a design"
  end

  test "the Review lead reads ready to merge once the review is finished" do
    done = %Run{status: :finished, stage_outcome: :done}
    scratch = Path.join(System.tmp_dir!(), "role_status_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(scratch) end)
    File.mkdir_p!(Path.join(scratch, "reviews"))

    File.write!(
      Path.join(scratch, "reviews/RSL-1.json"),
      ~s({"passes": [{"round": 1, "saved_at": "2026-10-01T10:00:00Z", "finished_at": "2026-10-01T11:00:00Z"}]})
    )

    task = %Task{stage: :review, scratch_path: scratch, issue: %Issue{identifier: "RSL-1"}}

    assert role_status_label(%Role{stage: :review_lead}, done, task) == "ready to merge"
    assert role_status_label(%Role{stage: :review_lead}, %Run{status: :running}, task) == "in progress"
    assert role_status_label(%Role{stage: :engineer}, done, task) == "done"
  end

  test "a role the task has moved past is only done" do
    done = %Run{status: :finished, stage_outcome: :done}

    assert role_status_label(%Role{stage: :plan}, done, %Task{stage: :engineer}) == "done"
  end

  # Finalize has its own tab, so the Review tab behind it reads done, not needs review.
  test "the Review lead reads done once the task is at Finalize or merged" do
    done = %Run{status: :finished, stage_outcome: :done}

    assert role_status_label(%Role{stage: :review_lead}, done, %Task{stage: :finalize}) == "done"
    assert role_status_label(%Role{stage: :review_lead}, done, %Task{stage: :merged}) == "done"
  end

  describe "on a fix round" do
    setup do
      scratch = Path.join(System.tmp_dir!(), "role_status_fix_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(scratch) end)
      File.mkdir_p!(Path.join(scratch, "fix_plans"))
      task = %Task{id: "tsk_role_status_fix", stage: :review, scratch_path: scratch, issue: %Issue{identifier: "RSF-1"}}

      %{
        task: task,
        path: Path.join(scratch, "fix_plans/RSF-1.json"),
        sent: %{round: 2, findings: [], comments: [%{number: 1, kind: "diff", text: "Why?"}]}
      }
    end

    test "the Review tab reads the plan to approve, or out of date once a ruling changed", %{
      task: task,
      path: path,
      sent: sent
    } do
      done = %Run{status: :finished, stage_outcome: :done}
      lead = %Role{stage: :review_lead}
      File.write!(path, Jason.encode!(Map.merge(sent, %{plan: "p", covered_comments: 1})))
      assert role_status_label(lead, done, task) == "fix plan to approve"

      outdated = Map.merge(sent, %{plan: "p", covered_comments: 1, covered_keys: ["gone"], findings: [%{key: "gone"}]})
      File.write!(path, Jason.encode!(outdated))
      assert role_status_label(lead, done, task) == "fix plan out of date"
      assert role_status_label(%Role{stage: :engineer}, done, task) == "done"
    end

    test "while the round works or stops it reads writing, revising, fixing or stopped with its number", %{
      task: task,
      path: path,
      sent: sent
    } do
      lead = %Role{stage: :review_lead}
      running = %Run{status: :running}
      File.write!(path, Jason.encode!(sent))
      assert role_status_label(lead, running, task) == "fix round 2 · writing the fix plan"
      assert role_status_label(lead, %Run{status: :finished}, task) == "fix round 2 · stopped"
      assert role_status_label(lead, %Run{status: :finished, error: "No plan."}, task) == "fix round 2 · stopped"

      File.write!(path, Jason.encode!(Map.merge(sent, %{plan: "p", covered_comments: 0})))
      assert role_status_label(lead, running, task) == "fix round 2 · revising the fix plan"

      # Approved, the round is fixing on the commit its last pass read, and a later round is no longer.
      worktree = create_temp_git_repo()
      head = worktree |> git!(["rev-parse", "HEAD"]) |> String.trim()
      File.mkdir_p!(Path.join(task.scratch_path, "reviews"))

      File.write!(
        Path.join(task.scratch_path, "reviews/RSF-1.json"),
        Jason.encode!(%{passes: [%{round: 1, saved_at: "2026-10-12T16:00:00Z", head: head}]})
      )

      File.write!(
        path,
        Jason.encode!(Map.merge(sent, %{plan: "p", covered_comments: 1, approved_at: "2026-10-12T16:58:00Z"}))
      )

      approved = %{task | worktree_path: worktree}
      assert role_status_label(lead, running, approved) == "fix round 2 · fixing"
      File.rm!(Path.join(task.scratch_path, "reviews/RSF-1.json"))
      assert role_status_label(lead, running, approved) == "in progress"

      File.write!(
        Path.join(task.scratch_path, "reviews/RSF-1.json"),
        Jason.encode!(%{passes: [%{round: 1, saved_at: "2026-10-12T16:00:00Z", head: head}]})
      )

      git!(worktree, ["commit", "--allow-empty", "-m", "The fix"])
      assert role_status_label(lead, running, approved) == "in progress"

      assert role_status_label(lead, running, %{approved | worktree_path: Path.join(task.scratch_path, "gone")}) ==
               "in progress"
    end
  end
end
