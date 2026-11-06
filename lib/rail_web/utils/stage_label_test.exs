defmodule RailWeb.Utils.StageLabelTest do
  use Rail.DataCase, async: true

  import RailWeb.Utils.RunStateStyle
  import RailWeb.Utils.StageLabel

  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Schemas.IssueStage
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Round
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Roles.Schemas.Role

  test "a child of a split with no run reads what its earlier siblings hold it on" do
    siblings = [
      %Task{split_position: 1, issue: %Issue{identifier: "SPL-1", state: :in_progress}},
      %Task{split_position: 2, issue: %Issue{identifier: "SPL-2", state: :canceled}},
      %Task{split_position: 3, issue: %Issue{identifier: "SPL-3", state: :done, completed_at: ~U[2026-10-07 10:00:00Z]}}
    ]

    child = &%Task{stage: :engineer, runs: [], builds_on: &1, parent_task: %Task{children: siblings}}

    assert stage_label(child.([1, 3]), nil) == "Waiting on SPL-1"
    assert stage_label(child.([1, 2]), nil) == "Blocked by SPL-2"
    assert stage_label(child.([3]), nil) == "Queued for Implement"
    assert stage_label(child.([1, 4]), nil) == "Blocked by child 4"
  end

  test "no task at all is something waiting on you" do
    assert stage_label(nil, nil) == "Waiting on you"
  end

  test "a merged task says it merged, whatever its last run did" do
    assert stage_label(%Task{stage: :merged}, nil) == "Merged"
    assert stage_label(%Task{stage: :merged}, %Run{status: :finished, stage_outcome: :done}) == "Merged"
    assert stage_label(%Task{stage: :split}, %Run{status: :finished, stage_outcome: :done}) == "Plan approved"
  end

  test "a stage that has not started is queued for it" do
    assert stage_label(%Task{stage: :plan}, nil) == "Queued for Plan"
  end

  test "a working stage says so" do
    assert stage_label(%Task{stage: :plan}, %Run{status: :running}) == "Plan running"
    assert stage_label(%Task{stage: :engineer}, %Run{status: :waiting_for_resources}) == "Implement waiting for resources"
    assert stage_label(%Task{stage: :engineer}, %Run{status: :waiting_for_usage}) == "Implement waiting for usage"
  end

  test "a stage parked on a question asks for the answer" do
    assert stage_label(%Task{stage: :plan}, %Run{status: :blocked_on_input}) == "Plan needs an answer"
  end

  test "a stage that hit an error says it failed" do
    assert stage_label(%Task{stage: :plan}, %Run{status: :finished, error: "boom"}) == "Plan failed"
  end

  test "a stage that stopped without saying anything reads as stopped" do
    assert stage_label(%Task{stage: :plan}, %Run{status: :finished}) == "Plan stopped"
  end

  test "a stage that concluded says what the human has to decide" do
    done = %Run{status: :finished, stage_outcome: :done}
    scratch = Path.join(System.tmp_dir!(), "stage_label_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(scratch) end)

    assert stage_label(%Task{stage: :plan, scratch_path: scratch}, done) == "Review the plan"
    assert stage_label(%Task{stage: :engineer}, done) == "Review the diff"
    assert stage_label(%Task{stage: :review}, done) == "Review"
    assert approval_label(%Task{stage: :merged}) == "Waiting on you"
  end

  test "a Review run done reads the findings until the review is finished, and then is ready to merge" do
    done = %Run{status: :finished, stage_outcome: :done}
    scratch = Path.join(System.tmp_dir!(), "stage_label_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(scratch) end)
    task = %Task{stage: :review, scratch_path: scratch, issue: %Issue{identifier: "STL-1"}}
    File.mkdir_p!(Path.join(scratch, "reviews"))

    assert approval_label(task) == "Review"
    refute ready_to_merge?(task, done)

    File.write!(
      Path.join(scratch, "reviews/STL-1.json"),
      ~s({"passes": [{"round": 1, "saved_at": "2026-10-01T10:00:00Z", "head": "abc"}]})
    )

    assert stage_label(task, done) == "Review"
    refute ready_to_merge?(task, done)

    File.write!(
      Path.join(scratch, "reviews/STL-1.json"),
      ~s({"passes": [{"round": 1, "saved_at": "2026-10-01T10:00:00Z", "head": "abc", "finished_at": "2026-10-01T11:00:00Z"}]})
    )

    assert stage_label(task, done) == "Ready to merge"
    assert ready_to_merge?(task, done)
    refute ready_to_merge?(task, %Run{status: :running})
    refute ready_to_merge?(%{task | stage: :engineer}, done)
  end

  test "a Review lead run that stopped, failed or asked reads so, even with a saved pass on disk" do
    scratch = Path.join(System.tmp_dir!(), "stage_label_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(scratch) end)
    task = %Task{stage: :review, scratch_path: scratch, issue: %Issue{identifier: "STL-2"}}
    File.mkdir_p!(Path.join(scratch, "reviews"))

    File.write!(
      Path.join(scratch, "reviews/STL-2.json"),
      ~s({"passes": [{"round": 1, "saved_at": "2026-10-01T10:00:00Z", "head": "abc"}]})
    )

    lead = %Run{status: :finished, role: %Role{stage: :review_lead}, questions: []}

    assert stage_label(task, lead) == "Review stopped"
    assert stage_label(task, %{lead | error: "The Review lead did not save its review."}) == "Review failed"
    assert stage_label(task, %{lead | questions: [%Question{status: :pending}]}) == "Review needs an answer"
    assert stage_label(task, %{lead | status: :blocked_on_input}) == "Review needs an answer"
  end

  test "only a done Review lead run at Review that is not ready to merge waits on a review" do
    scratch = Path.join(System.tmp_dir!(), "stage_label_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(scratch) end)
    task = %Task{stage: :review, scratch_path: scratch, issue: %Issue{identifier: "STL-3"}}
    done = %Run{status: :finished, stage_outcome: :done, role: %Role{stage: :review_lead}}

    assert review_waiting?(task, done)

    refute review_waiting?(task, %{done | status: :blocked_on_input})
    refute review_waiting?(task, %{done | stage_outcome: :in_progress})
    refute review_waiting?(task, %{done | stage_outcome: :in_progress, error: "boom"})
    refute review_waiting?(task, %{done | role: %Role{stage: :plan}})
    refute review_waiting?(%{task | stage: :plan}, %{done | role: %Role{stage: :plan}})
    refute review_waiting?(%{task | stage: :engineer}, %{done | role: %Role{stage: :engineer}})
    refute review_waiting?(task, nil)

    File.mkdir_p!(Path.join(scratch, "reviews"))

    File.write!(
      Path.join(scratch, "reviews/STL-3.json"),
      ~s({"passes": [{"round": 1, "saved_at": "2026-10-01T10:00:00Z", "head": "abc", "finished_at": "2026-10-01T11:00:00Z"}]})
    )

    refute review_waiting?(task, done)
  end

  test "a Plan run done with options and no pick asks for the pick, and once picked for the review" do
    done = %Run{status: :finished, stage_outcome: :done}
    scratch = Path.join(System.tmp_dir!(), "stage_label_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(scratch) end)
    task = %Task{stage: :plan, scratch_path: scratch}

    options = for key <- ["a", "b", "c"], do: %{"key" => key, "title" => String.upcase(key)}
    File.mkdir_p!(Path.join(scratch, "design"))
    File.write!(Path.join(scratch, "design/manifest.json"), Jason.encode!(%{"options" => options}))

    assert waiting_on_pick?(task)
    assert stage_label(task, done) == "Pick a design"

    File.write!(Path.join(scratch, "design/picked"), "b")

    refute waiting_on_pick?(task)
    assert stage_label(task, done) == "Review the plan"
  end

  test "a plan sent to the tech leads reads Ready for tech lead once its run is done, and as its run otherwise" do
    sent = %Task{stage: :plan, rounds: [%Round{number: 1, ready_at: DateTime.utc_now()}]}
    done = %Run{status: :finished, stage_outcome: :done}

    assert stage_label(sent, done) == "Ready for tech lead"
    assert sent_plan_waiting?(sent, done)
    assert stage_label(sent, %Run{status: :blocked_on_input}) == "Plan needs an answer"
    refute sent_plan_waiting?(sent, %Run{status: :blocked_on_input})
    assert stage_label(sent, %Run{status: :finished, error: "It went wrong"}) == "Plan failed"
    assert stage_label(sent, %Run{status: :finished}) == "Plan stopped"
    refute sent_plan_waiting?(%{sent | stage: :engineer}, done)
  end

  test "a task at Finalize reads where it stands there while its Review run is idle" do
    now = DateTime.utc_now()

    for run <- [nil, %Run{status: :finished, stage_outcome: :done}, %Run{status: :finished, error: "Gave up."}] do
      assert stage_label(%Task{stage: :finalize}, run) == "Ready to finalize"
      assert stage_label(%Task{stage: :finalize, marked_ready_at: now}, run) == "Ready for tech lead"
      assert stage_label(%Task{stage: :finalize, marked_ready_at: now, merge_started_at: now}, run) == "Merging"
      assert stage_label(%Task{stage: :finalize, marked_ready_at: now, merge_error: "No"}, run) == "Merge refused"
      assert stage_label(%Task{stage: :merged, merged_at: now}, run) == "Merged"
    end
  end

  test "a task at Finalize whose run a comment resumed reads as that run until it is done, unless it is merging" do
    now = DateTime.utc_now()
    running = %Run{status: :running, stage_outcome: :done}

    assert stage_label(%Task{stage: :finalize}, running) == "Finalize running"
    assert stage_label(%Task{stage: :finalize, marked_ready_at: now}, running) == "Finalize running"
    assert stage_label(%Task{stage: :finalize}, %Run{status: :waiting_for_resources}) == "Finalize waiting for resources"
    assert stage_label(%Task{stage: :finalize}, %Run{status: :waiting_for_usage}) == "Finalize waiting for usage"
    assert stage_label(%Task{stage: :finalize}, %Run{status: :blocked_on_input}) == "Finalize needs an answer"
    assert stage_label(%Task{stage: :finalize, marked_ready_at: now, merge_started_at: now}, running) == "Merging"
    assert stage_label(%Task{stage: :merged, merged_at: now}, running) == "Merged"
  end

  test "a custom stage reads by its name, and once its agent stops waits on a person's Approve or on its file" do
    scratch = Path.join(System.tmp_dir!(), "stage_label_custom_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(scratch) end)
    stages = [%IssueStage{stage: :custom, name: "License check", prompt: "Check."}, %IssueStage{stage: :review}]
    task = %Task{stage: :custom, custom_stage: "License check", scratch_path: scratch, issue: %Issue{stages: stages}}
    stopped = %Run{status: :finished, stage_outcome: :in_progress}

    assert stage_label(task, %Run{status: :running}) == "License check running"
    assert stage_label(task, %Run{status: :waiting_for_usage}) == "License check waiting for usage"
    assert stage_label(task, stopped) == "License check needs you"
    refute custom_stage_waiting?(task, stopped)
    assert %{icon: "pi-warning-circle"} = run_state_style(stopped, task)

    File.mkdir_p!(Path.join(scratch, "stages"))
    File.write!(Path.join([scratch, "stages", "1-license-check.md"]), "All MIT.")

    assert stage_label(task, stopped) == "Review License check"
    assert custom_stage_waiting?(task, stopped)
    assert %{icon: "pi-hand-pointing"} = run_state_style(stopped, task)
    assert %{icon: "pi-play-circle"} = run_state_style(%Run{status: :running}, task)
    refute custom_stage_waiting?(%Task{stage: :engineer}, stopped)
  end

  test "a running engineer run reads Implement running" do
    assert stage_label(%Task{stage: :engineer}, %Run{status: :running}) == "Implement running"
  end

  # Finalize records the merge before Linear completes the issue, and the child need not wait for Linear.
  test "a child is not held on a sibling merged through Finalize" do
    siblings = [%Task{split_position: 1, merged_at: DateTime.utc_now(), issue: %Issue{identifier: "SPL-1"}}]
    child = %Task{stage: :engineer, runs: [], builds_on: [1], parent_task: %Task{children: siblings}}

    assert stage_label(child, nil) == "Queued for Implement"
  end

  describe "fix_plan_waiting?/1" do
    setup do
      scratch = Path.join(System.tmp_dir!(), "stage_label_fix_plan_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(scratch) end)
      File.mkdir_p!(Path.join(scratch, "fix_plans"))
      task = %Task{id: "tsk_stage_label_plan", stage: :review, scratch_path: scratch, issue: %Issue{identifier: "SLP-1"}}
      %{task: task, path: Path.join(scratch, "fix_plans/SLP-1.json")}
    end

    test "is true for a saved plan waiting on the person, approvable or out of date", %{task: task, path: path} do
      sent = %{round: 1, findings: [], comments: [%{number: 1, kind: "diff", text: "Why?"}]}
      File.write!(path, Jason.encode!(Map.merge(sent, %{plan: "### What changes", covered_comments: 1, version: 1})))
      assert fix_plan_waiting?(task)

      # A finding the round sent is no longer ruled Fix, since it is not on the task.
      out_of_date = Map.merge(sent, %{plan: "p", covered_comments: 1, covered_keys: ["gone"], findings: [%{key: "gone"}]})
      File.write!(path, Jason.encode!(out_of_date))
      assert fix_plan_waiting?(task)

      # The header still names the stage.
      assert approval_label(task) == "Review"
    end

    test "is false while the plan is written, revised or approved, and with none", %{task: task, path: path} do
      sent = %{round: 1, findings: [], comments: [%{number: 1, kind: "diff", text: "Why?"}]}
      File.write!(path, Jason.encode!(sent))
      refute fix_plan_waiting?(task)

      File.write!(path, Jason.encode!(Map.merge(sent, %{plan: "p", covered_comments: 0})))
      refute fix_plan_waiting?(task)

      File.write!(
        path,
        Jason.encode!(Map.merge(sent, %{plan: "p", covered_comments: 1, approved_at: "2026-10-12T16:58:00Z"}))
      )

      refute fix_plan_waiting?(task)

      File.rm!(path)
      refute fix_plan_waiting?(task)
      refute fix_plan_waiting?(%Task{stage: :review})
    end
  end

  describe "waiting_path/1" do
    setup do
      scratch = Path.join(System.tmp_dir!(), "waiting_path_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(scratch) end)

      waiting = fn stage, role_stage, attrs ->
        task = %Task{id: "tsk_1", stage: stage, scratch_path: scratch, issue: %Issue{identifier: "WTP-1"}}
        struct(%Run{task_id: "tsk_1", questions: [], task: task, role: %Role{stage: role_stage}}, attrs)
      end

      %{scratch: scratch, waiting: waiting}
    end

    test "opens a question in its agent's conversation, unless the task opens there by itself", %{waiting: waiting} do
      asked = %{status: :blocked_on_input}

      assert waiting_path(waiting.(:engineer, :engineer, asked)) == "/tasks/tsk_1?item=plan&agent=engineer"
      assert waiting_path(waiting.(:plan, :plan, asked)) == "/tasks/tsk_1"
      assert waiting_path(waiting.(:review, :review_lead, asked)) == "/tasks/tsk_1"
      assert waiting_path(waiting.(:plan, :engineer, asked)) == "/tasks/tsk_1?item=plan&agent=engineer"
    end

    test "a custom stage's own agent takes its question where the task opens", %{waiting: waiting} do
      run = waiting.(:custom, nil, %{status: :blocked_on_input})
      task = %{run.task | custom_stage: "License check"}

      assert waiting_path(%{run | task: task, role: %Role{custom_stage: "License check"}}) == "/tasks/tsk_1"
    end

    test "a change ready to merge opens on its findings, and one at Finalize on the task", %{
      scratch: scratch,
      waiting: waiting
    } do
      File.mkdir_p!(Path.join(scratch, "reviews"))
      done = %{status: :finished, stage_outcome: :done}
      at_finalize = waiting.(:finalize, :review_lead, done)

      assert waiting_path(at_finalize) == "/tasks/tsk_1"
      refute ready_to_merge?(waiting.(:review, :review_lead, done))
      refute ready_to_merge?(waiting.(:plan, :plan, done))
    end

    test "a fix plan waiting on a person opens the plan, at Review and at Finalize", %{
      scratch: scratch,
      waiting: waiting
    } do
      File.mkdir_p!(Path.join(scratch, "fix_plans"))

      File.write!(
        Path.join(scratch, "fix_plans/WTP-1.json"),
        Jason.encode!(%{round: 1, findings: [], comments: [], plan: "p", covered_comments: 0})
      )

      done = %{status: :finished, stage_outcome: :done}

      for stage <- [:review, :finalize] do
        run = waiting.(stage, :review_lead, done)

        assert waiting_fix_plan?(run)
        assert waiting_path(run) == "/tasks/tsk_1?item=fix_plan"
      end

      refute waiting_fix_plan?(waiting.(:review, :review_lead, %{status: :running}))
      refute waiting_fix_plan?(waiting.(:plan, :plan, done))
    end

    test "only a done run at Finalize is finalizing", %{waiting: waiting} do
      assert finalizing?(waiting.(:finalize, :review_lead, %{status: :finished, stage_outcome: :done}))
      refute finalizing?(waiting.(:finalize, :review_lead, %{status: :running}))
      refute finalizing?(waiting.(:review, :review_lead, %{status: :finished, stage_outcome: :done}))
    end
  end
end
