defmodule Rail.Pipeline.Actions.SettleRunTest do
  use Rail.DataCase, async: false

  alias Rail.Domain.TaskUsage
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Plan
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Roles.Schemas.Role
  alias Rail.Runs.QuestionDetector
  alias Rail.Runs.Schemas.RoleRun
  alias Rail.Runs.Schemas.Run

  test "returns not_found when task cannot be resolved" do
    %RoleRun{id: role_run_id} = create_test_role_run()

    assert {:error, :not_found} =
             Pipeline.settle_run("tsk_000000000000000000000000", role_run_id)
  end

  test "returns not_found when role_run cannot be resolved" do
    %Task{id: task_id} = create_test_task()

    assert {:error, :not_found} =
             Pipeline.settle_run(task_id, "rr_000000000000000000000000")
  end

  test "settles clean exit 0 for product stage advancing to design when design role exists" do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")
    project = create_test_project()
    _product_role = create_test_role(%{project_id: project.id, stage: :product})
    _design_role = create_test_role(%{project_id: project.id, stage: :design})

    %Task{id: task_id} =
      task = create_test_task(%{project_id: project.id, stage: :product, stage_state: :running})

    role_run = create_test_role_run(%{task_id: task_id, status: :running})

    assert {:ok, %Task{id: ^task_id, stage: :design, stage_state: :queued},
            %RoleRun{status: :finished, exit_code: 0, auto_retries: 0}} =
             Pipeline.settle_run(task, role_run, %{exit_code: 0})

    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :run_settled}}
  end

  test "settles clean exit 0 for product stage skipping to architect when design role absent" do
    project = create_test_project()
    _product_role = create_test_role(%{project_id: project.id, stage: :product})

    %Task{id: task_id} =
      task = create_test_task(%{project_id: project.id, stage: :product, stage_state: :running})

    role_run = create_test_role_run(%{task_id: task_id, status: :running})

    assert {:ok, %Task{id: ^task_id, stage: :architect, stage_state: :queued}, %RoleRun{status: :finished, exit_code: 0}} =
             Pipeline.settle_run(task, role_run, %{exit_code: 0})
  end

  test "settles clean exit 0 for architect stage advancing to awaiting_approval when plan exists" do
    project = create_test_project()

    %Task{id: task_id} =
      task = create_test_task(%{project_id: project.id, stage: :architect, stage_state: :running})

    _plan = create_test_plan(%{task_id: task_id, content: "# Architecture Plan"})
    role_run = create_test_role_run(%{task_id: task_id, status: :running})

    assert {:ok, %Task{id: ^task_id, stage_state: :awaiting_approval, retry_after: nil, error: nil},
            %RoleRun{status: :finished, exit_code: 0}} =
             Pipeline.settle_run(task, role_run, %{exit_code: 0})
  end

  test "settles clean exit 0 for architect stage failing when plan file was not written" do
    project = create_test_project()

    %Task{id: task_id} =
      task = create_test_task(%{project_id: project.id, stage: :architect, stage_state: :running})

    role_run = create_test_role_run(%{task_id: task_id, status: :running})

    assert {:ok, %Task{id: ^task_id, stage_state: :failed, error: error_msg}, %RoleRun{status: :finished, exit_code: 0}} =
             Pipeline.settle_run(task, role_run, %{exit_code: 0})

    assert error_msg =~ "without writing a plan"
  end

  test "settles clean exit 0 for engineer stage advancing to review" do
    project = create_test_project()

    %Task{id: task_id} =
      task = create_test_task(%{project_id: project.id, stage: :engineer, stage_state: :running})

    role_run = create_test_role_run(%{task_id: task_id, status: :running})

    assert {:ok, %Task{id: ^task_id, stage: :review, stage_state: :queued}, %RoleRun{status: :finished, exit_code: 0}} =
             Pipeline.settle_run(task, role_run, %{exit_code: 0})
  end

  test "settles clean exit 0 for rebasing task restoring previous stage state" do
    project = create_test_project()

    %Task{id: task_id} =
      task =
      create_test_task(%{
        project_id: project.id,
        stage: :ready_to_merge,
        stage_state: :running,
        is_rebasing: true,
        stage_state_before_rebase: :awaiting_approval
      })

    role_run = create_test_role_run(%{task_id: task_id, status: :running})

    assert {:ok,
            %Task{
              id: ^task_id,
              is_rebasing: false,
              stage_state: :awaiting_approval,
              stage_state_before_rebase: nil
            }, %RoleRun{status: :finished, exit_code: 0, auto_retries: 0}} =
             Pipeline.settle_run(task, role_run, %{exit_code: 0})
  end

  test "settles clean exit 0 for generic stage setting awaiting_approval" do
    project = create_test_project()

    %Task{id: task_id} =
      task = create_test_task(%{project_id: project.id, stage: :design, stage_state: :running})

    role_run = create_test_role_run(%{task_id: task_id, status: :running})

    assert {:ok, %Task{id: ^task_id, stage_state: :awaiting_approval}, %RoleRun{status: :finished, exit_code: 0}} =
             Pipeline.settle_run(task, role_run, %{exit_code: 0})
  end

  test "handles transient failure with retry backoff when auto retries remain" do
    project = create_test_project()

    %Task{id: task_id} =
      task = create_test_task(%{project_id: project.id, stage: :engineer, stage_state: :running})

    role_run = create_test_role_run(%{task_id: task_id, status: :running, auto_retries: 0})

    transient_err = "rate limit exceeded: 429 too many requests"

    assert {:ok,
            %Task{
              id: ^task_id,
              stage_state: :queued,
              retry_after: %DateTime{},
              error: ^transient_err
            }, %RoleRun{status: :finished, auto_retries: 1, exit_code: 1}} =
             Pipeline.settle_run(task, role_run, %{exit_code: 1, error: transient_err})
  end

  test "handles transient failure marking failed when max auto retries are exhausted" do
    project = create_test_project()

    %Task{id: task_id} =
      task = create_test_task(%{project_id: project.id, stage: :engineer, stage_state: :running})

    role_run = create_test_role_run(%{task_id: task_id, status: :running, auto_retries: 2})

    transient_err = "rate limit exceeded: 429 too many requests"

    assert {:ok, %Task{id: ^task_id, stage_state: :failed, retry_after: nil, error: ^transient_err},
            %RoleRun{status: :finished, auto_retries: 2, exit_code: 1}} =
             Pipeline.settle_run(task, role_run, %{exit_code: 1, error: transient_err})
  end

  test "handles permanent failure immediately marking task and role run as failed" do
    project = create_test_project()

    %Task{id: task_id} =
      task = create_test_task(%{project_id: project.id, stage: :engineer, stage_state: :running})

    role_run = create_test_role_run(%{task_id: task_id, status: :running, auto_retries: 0})

    perm_err = "fatal syntax error: unexpected token"

    assert {:ok, %Task{id: ^task_id, stage_state: :failed, error: ^perm_err},
            %RoleRun{status: :finished, auto_retries: 0, exit_code: 1}} =
             Pipeline.settle_run(task, role_run, %{exit_code: 1, error: perm_err})
  end

  test "resolves string keys, updates associated Run, and captures scratch artifacts" do
    project = create_test_project()
    scratch_dir = create_temp_scratch_dir()

    %Task{id: task_id} =
      create_test_task(%{project_id: project.id, stage: :architect, stage_state: :running})

    %RoleRun{id: role_run_id} =
      create_test_role_run(%{task_id: task_id, status: :running})

    %Run{id: run_id} = run = create_test_run(%{task_id: task_id, role_run_id: role_run_id, status: :running})

    plan_path = Path.join(scratch_dir, "plan.md")
    File.write!(plan_path, "# Captured Architecture Plan")

    outcome = %{
      "exit_code" => 0,
      "output" => "Run finished cleanly",
      "usage" => %{"input_tokens" => 500, "output_tokens" => 150},
      :run => run
    }

    assert {:ok, %Task{id: ^task_id, stage_state: :awaiting_approval},
            %RoleRun{id: ^role_run_id, status: :finished, output: "Run finished cleanly"}} =
             Pipeline.settle_run(task_id, role_run_id, outcome, scratch_dir: scratch_dir)

    assert %Run{id: ^run_id, status: :finished} = Repo.get!(Run, run_id)
    assert %Plan{content: plan_content} = Repo.one(from p in Plan, where: p.task_id == ^task_id)
    assert plan_content =~ "Captured Architecture Plan"
  end

  test "resolves exit code, output, error, and usage fallbacks from role_run or defaults" do
    project = create_test_project()

    %Task{id: task_id} =
      task = create_test_task(%{project_id: project.id, stage: :design, stage_state: :running})

    role_run =
      create_test_role_run(%{
        task_id: task_id,
        status: :running,
        exit_code: 0,
        output: "prior output",
        error: nil
      })

    assert {:ok, %Task{id: ^task_id, stage_state: :awaiting_approval}, %RoleRun{output: "prior output"}} =
             Pipeline.settle_run(task, role_run, %{})
  end

  test "maybe_finish_run updates run when passed as top-level run struct" do
    project = create_test_project()

    %Task{id: task_id} =
      task = create_test_task(%{project_id: project.id, stage: :design, stage_state: :running})

    role_run = create_test_role_run(%{task_id: task_id, status: :running})
    %Run{id: run_id} = run = create_test_run(%{task_id: task_id, role_run_id: role_run.id, status: :running})

    assert {:ok, _task, _role_run} = Pipeline.settle_run(task, role_run, run)
    assert %Run{id: ^run_id, status: :finished} = Repo.get!(Run, run_id)
  end

  test "returns not_found when targets are invalid types" do
    project = create_test_project()
    task = create_test_task(%{project_id: project.id, stage: :design, stage_state: :running})
    role_run = create_test_role_run(%{task_id: task.id, status: :running})

    assert {:error, :not_found} = Pipeline.settle_run(12_345, role_run)
    assert {:error, :not_found} = Pipeline.settle_run(task, 12_345)
  end

  test "resolves fallback exit code, string error, and prior role_run error" do
    project = create_test_project()

    %Task{id: task_id} =
      task = create_test_task(%{project_id: project.id, stage: :design, stage_state: :running})

    role_run = create_test_role_run(%{task_id: task_id, status: :running, exit_code: nil, error: nil})

    assert {:ok, _t1, %RoleRun{exit_code: 0}} = Pipeline.settle_run(task, role_run, %{})

    assert {:ok, _t2, %RoleRun{error: "string err"}} =
             Pipeline.settle_run(task, role_run, %{"error" => "string err", "exit_code" => 1})

    role_run_err = create_test_role_run(%{task_id: task_id, status: :running, exit_code: 1, error: "prior err"})

    assert {:ok, _t3, %RoleRun{error: "prior err"}} =
             Pipeline.settle_run(task, role_run_err, %{"exit_code" => 1})
  end

  test "resolves atom-keyed output and various usage input formats" do
    project = create_test_project()

    %Task{id: task_id} =
      task = create_test_task(%{project_id: project.id, stage: :design, stage_state: :running})

    role_run = create_test_role_run(%{task_id: task_id, status: :running})

    assert {:ok, _t1, %RoleRun{output: "atom output"}} =
             Pipeline.settle_run(task, role_run, %{output: "atom output"})

    usage_struct = %TaskUsage{input_tokens: 42, output_tokens: 10}

    assert {:ok, _t2, %RoleRun{usage: %TaskUsage{input_tokens: 42}}} =
             Pipeline.settle_run(task, role_run, %{usage: usage_struct})

    assert {:ok, _t3, %RoleRun{usage: %TaskUsage{input_tokens: 55}}} =
             Pipeline.settle_run(task, role_run, %{usage: %{"input_tokens" => 55}})

    assert {:ok, _t4, %RoleRun{usage: %TaskUsage{input_tokens: 42}}} =
             Pipeline.settle_run(task, role_run, %{"usage" => usage_struct})
  end

  test "settles clean exit 0 for review stage with passed verdict advancing to qa" do
    project = create_test_project()
    %Role{id: role_rev_id} = role_rev = create_test_role(%{project_id: project.id, stage: :review, name: "Reviewer"})
    _role_qa = create_test_role(%{project_id: project.id, stage: :qa, name: "QA"})
    git_repo = create_temp_git_repo()

    %Task{id: task_id} =
      task =
      create_test_task(%{
        project_id: project.id,
        stage: :review,
        stage_state: :running,
        worktree_path: git_repo
      })

    role_run = create_test_role_run(%{task_id: task_id, role_id: role_rev.id, status: :running})

    output = "Code looks great!\n\nVERDICT: APPROVED"

    assert {:ok,
            %Task{
              id: ^task_id,
              stage: :qa,
              stage_state: :queued,
              outstanding_reports: [^role_rev_id]
            },
            %RoleRun{
              status: :finished,
              exit_code: 0,
              stage_fingerprint_head_sha: head_sha,
              stage_fingerprint_dirty_digest: dirty_digest
            }} = Pipeline.settle_run(task, role_run, %{exit_code: 0, output: output})

    assert is_binary(head_sha) and head_sha != ""
    assert is_binary(dirty_digest) and dirty_digest != ""
  end

  test "settles clean exit 0 for qa stage with passed verdict advancing to qa_lead" do
    project = create_test_project()
    %Role{id: role_qa_id} = role_qa = create_test_role(%{project_id: project.id, stage: :qa, name: "QA Tester"})
    _role_lead = create_test_role(%{project_id: project.id, stage: :qa_lead, name: "QA Lead"})

    %Task{id: task_id} =
      task =
      create_test_task(%{
        project_id: project.id,
        stage: :qa,
        stage_state: :running
      })

    role_run = create_test_role_run(%{task_id: task_id, role_id: role_qa.id, status: :running})

    output = "Test checklist passed.\n\nVERDICT: PASS"

    assert {:ok,
            %Task{
              id: ^task_id,
              stage: :qa_lead,
              stage_state: :queued,
              outstanding_reports: [^role_qa_id]
            }, %RoleRun{status: :finished}} =
             Pipeline.settle_run(task, role_run, %{exit_code: 0, output: output})
  end

  test "settles clean exit 0 for qa_lead stage with passed verdict advancing to demo if configured" do
    project = create_test_project()
    role_lead = create_test_role(%{project_id: project.id, stage: :qa_lead, name: "QA Lead"})
    _role_demo = create_test_role(%{project_id: project.id, stage: :demo, name: "Demo Recorder"})

    %Task{id: task_id} =
      task =
      create_test_task(%{
        project_id: project.id,
        stage: :qa_lead,
        stage_state: :running
      })

    role_run = create_test_role_run(%{task_id: task_id, role_id: role_lead.id, status: :running})

    output = "QA Lead evaluation successful.\n\nVERDICT: PASSED"

    assert {:ok,
            %Task{
              id: ^task_id,
              stage: :demo,
              stage_state: :queued
            }, %RoleRun{status: :finished}} =
             Pipeline.settle_run(task, role_run, %{exit_code: 0, output: output})
  end

  test "settles clean exit 0 for qa_lead stage with passed verdict advancing to ready_to_merge if no demo role" do
    project = create_test_project()
    role_lead = create_test_role(%{project_id: project.id, stage: :qa_lead, name: "QA Lead"})

    %Task{id: task_id} =
      task =
      create_test_task(%{
        project_id: project.id,
        stage: :qa_lead,
        stage_state: :running
      })

    role_run = create_test_role_run(%{task_id: task_id, role_id: role_lead.id, status: :running})

    output = "QA Lead evaluation successful.\n\nVERDICT: APPROVED"

    assert {:ok,
            %Task{
              id: ^task_id,
              stage: :ready_to_merge,
              stage_state: :awaiting_approval
            }, %RoleRun{status: :finished}} =
             Pipeline.settle_run(task, role_run, %{exit_code: 0, output: output})
  end

  test "settles gate with changes_requested within budget routing back to engineer with carried reports" do
    project = create_test_project()
    role_eng = create_test_role(%{project_id: project.id, stage: :engineer, name: "Engineer"})
    %Role{id: role_rev_id} = role_rev = create_test_role(%{project_id: project.id, stage: :review, name: "Reviewer"})
    role_prior = create_test_role(%{project_id: project.id, stage: :qa, name: "Prior QA"})

    %Task{id: task_id} =
      task =
      create_test_task(%{
        project_id: project.id,
        stage: :review,
        stage_state: :running,
        rework_cycles: 0,
        rework_budget_base: 0,
        rework_cycles_by_gate: %{},
        outstanding_reports: [role_prior.id]
      })

    create_test_role_run(%{
      task_id: task_id,
      role_id: role_prior.id,
      status: :finished,
      output: "Prior QA note: button is off-center."
    })

    role_run = create_test_role_run(%{task_id: task_id, role_id: role_rev.id, status: :running})

    output = "Please fix test coverage.\n\nVERDICT: CHANGES REQUESTED"

    assert {:ok,
            %Task{
              id: ^task_id,
              stage: :engineer,
              stage_state: :queued,
              rework_cycles: 1,
              rework_cycles_by_gate: %{^role_rev_id => 1},
              outstanding_reports: []
            }, %RoleRun{status: :finished}} =
             Pipeline.settle_run(task, role_run, %{exit_code: 0, output: output})

    engineer_run = Repo.one(from r in RoleRun, where: r.task_id == ^task_id and r.role_id == ^role_eng.id)
    assert engineer_run.pending_answer =~ "Findings from Reviewer on the change you just pushed (rework 1 of 5)"
    assert engineer_run.pending_answer =~ "Please fix test coverage."
    assert engineer_run.pending_answer =~ "Also outstanding: what the other gates last reported"
    assert engineer_run.pending_answer =~ "### Prior QA\n\nPrior QA note: button is off-center."
  end

  test "settles gate with changes_requested parking for human when per-gate rework limit is reached" do
    project = create_test_project()
    role_rev = create_test_role(%{project_id: project.id, stage: :review, name: "Reviewer"})

    %Task{id: task_id} =
      task =
      create_test_task(%{
        project_id: project.id,
        stage: :review,
        stage_state: :running,
        rework_cycles: 3,
        rework_budget_base: 0,
        rework_cycles_by_gate: %{role_rev.id => 3}
      })

    role_run = create_test_role_run(%{task_id: task_id, role_id: role_rev.id, status: :running})

    output = "Still not fixed.\n\nVERDICT: FAIL"

    assert {:ok,
            %Task{
              id: ^task_id,
              stage: :review,
              stage_state: :awaiting_approval,
              rework_cycles: 3,
              error: err
            }, %RoleRun{status: :finished}} =
             Pipeline.settle_run(task, role_run, %{exit_code: 0, output: output})

    assert err =~ "Reviewer is still requesting changes after 3 rework cycles."
    assert err =~ "Send back to Engineer to have them addressed, or Skip"
  end

  test "settles gate with changes_requested parking for human when global rework ceiling is reached" do
    project = create_test_project()
    role_qa = create_test_role(%{project_id: project.id, stage: :qa, name: "QA Tester"})

    %Task{id: task_id} =
      task =
      create_test_task(%{
        project_id: project.id,
        stage: :qa,
        stage_state: :running,
        rework_cycles: 5,
        rework_budget_base: 0,
        rework_cycles_by_gate: %{"other_gate" => 2, role_qa.id => 1}
      })

    role_run = create_test_role_run(%{task_id: task_id, role_id: role_qa.id, status: :running})

    output = "QA failure.\n\nVERDICT: FAILED"

    assert {:ok,
            %Task{
              id: ^task_id,
              stage_state: :awaiting_approval,
              rework_cycles: 5,
              error: err
            }, %RoleRun{status: :finished}} =
             Pipeline.settle_run(task, role_run, %{exit_code: 0, output: output})

    assert err =~ "QA Tester is still requesting changes after 1 rework cycle."
  end

  test "settles gate with unclear verdict parking for human" do
    project = create_test_project()
    %Role{id: role_rev_id} = role_rev = create_test_role(%{project_id: project.id, stage: :review, name: "Reviewer"})

    %Task{id: task_id} =
      task =
      create_test_task(%{
        project_id: project.id,
        stage: :review,
        stage_state: :running
      })

    role_run = create_test_role_run(%{task_id: task_id, role_id: role_rev.id, status: :running})

    output = "Here are some notes but no verdict keyword."

    assert {:ok,
            %Task{
              id: ^task_id,
              stage_state: :awaiting_approval,
              error: err,
              outstanding_reports: [^role_rev_id]
            }, %RoleRun{status: :finished}} =
             Pipeline.settle_run(task, role_run, %{exit_code: 0, output: output})

    assert err =~ "Reviewer ended without a clear verdict. Read its report, then Send back to Engineer or Skip"
  end

  test "settles gate pass with rework stamping evidence commit line to next stage pending_answer" do
    project = create_test_project()
    role_rev = create_test_role(%{project_id: project.id, stage: :review, name: "Reviewer"})
    role_qa = create_test_role(%{project_id: project.id, stage: :qa, name: "QA Tester"})
    git_repo = create_temp_git_repo()

    %Task{id: task_id} =
      task =
      create_test_task(%{
        project_id: project.id,
        stage: :review,
        stage_state: :running,
        rework_cycles: 1,
        worktree_path: git_repo
      })

    role_run = create_test_role_run(%{task_id: task_id, role_id: role_rev.id, status: :running})

    output = "Rework resolved nicely.\n\nVERDICT: APPROVED"

    assert {:ok, %Task{stage: :qa, stage_state: :queued}, %RoleRun{stage_fingerprint_head_sha: head_sha}} =
             Pipeline.settle_run(task, role_run, %{exit_code: 0, output: output})

    qa_run = Repo.one(from r in RoleRun, where: r.task_id == ^task_id and r.role_id == ^role_qa.id)
    assert qa_run.pending_answer =~ "The change has been reworked and the reviewer has signed off on it again."
    assert qa_run.pending_answer =~ "The reworked change is commit #{head_sha}."
  end

  test "settles gate with changes_requested appending to existing engineer pending_answer or missing engineer role" do
    project = create_test_project()
    role_eng = create_test_role(%{project_id: project.id, stage: :engineer, name: "Engineer"})
    role_rev = create_test_role(%{project_id: project.id, stage: :review, name: "Reviewer"})

    %Task{id: task_id} =
      task =
      create_test_task(%{
        project_id: project.id,
        stage: :review,
        stage_state: :running,
        rework_cycles: 0,
        rework_budget_base: 0
      })

    create_test_role_run(%{
      task_id: task_id,
      role_id: role_eng.id,
      status: :finished,
      pending_answer: "Old engineer notes"
    })

    role_run = create_test_role_run(%{task_id: task_id, role_id: role_rev.id, status: :running})
    output = "Please fix tests.\n\nVERDICT: CHANGES REQUESTED"

    assert {:ok, %Task{stage: :engineer, stage_state: :queued}, %RoleRun{status: :finished}} =
             Pipeline.settle_run(task, role_run, %{exit_code: 0, output: output})

    eng_run = Repo.one(from r in RoleRun, where: r.task_id == ^task_id and r.role_id == ^role_eng.id)
    assert eng_run.pending_answer =~ "Old engineer notes\n\nFindings from Reviewer"

    # Part B: Project without engineer role
    project_no_eng = create_test_project()
    role_rev2 = create_test_role(%{project_id: project_no_eng.id, stage: :review, name: "Reviewer 2"})

    %Task{id: task_id2} =
      task2 =
      create_test_task(%{
        project_id: project_no_eng.id,
        stage: :review,
        stage_state: :running,
        rework_cycles: 0,
        rework_budget_base: 0
      })

    role_run2 = create_test_role_run(%{task_id: task_id2, role_id: role_rev2.id, status: :running})

    assert {:ok, %Task{stage: :engineer, stage_state: :queued}, %RoleRun{status: :finished}} =
             Pipeline.settle_run(task2, role_run2, %{exit_code: 0, output: output})
  end

  test "settles gate pass with rework from qa and qa_lead appending to existing pending_answer or missing next role" do
    project = create_test_project()
    role_qa = create_test_role(%{project_id: project.id, stage: :qa, name: "QA Tester"})
    role_lead = create_test_role(%{project_id: project.id, stage: :qa_lead, name: "QA Lead"})
    git_repo = create_temp_git_repo()

    %Task{id: task_id} =
      task =
      create_test_task(%{
        project_id: project.id,
        stage: :qa,
        stage_state: :running,
        rework_cycles: 1,
        worktree_path: git_repo
      })

    create_test_role_run(%{
      task_id: task_id,
      role_id: role_lead.id,
      status: :finished,
      pending_answer: "Prior lead notes"
    })

    role_run = create_test_role_run(%{task_id: task_id, role_id: role_qa.id, status: :running})
    output = "QA passed cleanly.\n\nVERDICT: PASS"

    assert {:ok, %Task{stage: :qa_lead, stage_state: :queued}, %RoleRun{stage_fingerprint_head_sha: head_sha}} =
             Pipeline.settle_run(task, role_run, %{exit_code: 0, output: output})

    lead_run = Repo.one(from r in RoleRun, where: r.task_id == ^task_id and r.role_id == ^role_lead.id)

    assert lead_run.pending_answer =~
             "Prior lead notes\n\nThe change has been reworked and QA has signed off on it again."

    assert lead_run.pending_answer =~ "The reworked change is commit #{head_sha}."

    # Part B: QA lead pass with rework when project HAS a demo role (hits "the previous gate" label)
    role_demo = create_test_role(%{project_id: project.id, stage: :demo, name: "Demo Recorder"})

    %Task{id: task_id2} =
      task2 =
      create_test_task(%{
        project_id: project.id,
        stage: :qa_lead,
        stage_state: :running,
        rework_cycles: 1,
        worktree_path: git_repo
      })

    role_run2 = create_test_role_run(%{task_id: task_id2, role_id: role_lead.id, status: :running})
    output2 = "QA Lead pass.\n\nVERDICT: PASS"

    assert {:ok, %Task{stage: :demo, stage_state: :queued}, %RoleRun{stage_fingerprint_head_sha: head_sha2}} =
             Pipeline.settle_run(task2, role_run2, %{exit_code: 0, output: output2})

    demo_run = Repo.one(from r in RoleRun, where: r.task_id == ^task_id2 and r.role_id == ^role_demo.id)
    assert demo_run.pending_answer =~ "The change has been reworked and the previous gate has signed off on it again."
    assert demo_run.pending_answer =~ "The reworked change is commit #{head_sha2}."

    # Part C: Review stage pass with rework when next stage (:qa) role does NOT exist
    project_no_qa = create_test_project()
    role_rev3 = create_test_role(%{project_id: project_no_qa.id, stage: :review, name: "Reviewer 3"})

    %Task{id: task_id3} =
      task3 =
      create_test_task(%{
        project_id: project_no_qa.id,
        stage: :review,
        stage_state: :running,
        rework_cycles: 1,
        worktree_path: git_repo
      })

    role_run3 = create_test_role_run(%{task_id: task_id3, role_id: role_rev3.id, status: :running})

    assert {:ok, %Task{stage: :qa, stage_state: :queued}, %RoleRun{status: :finished}} =
             Pipeline.settle_run(task3, role_run3, %{exit_code: 0, output: "VERDICT: APPROVED"})

    # Part D: Gate unclear with unknown role ID falls back to to_string(role_id)
    unknown_role_id = "rol_unknown_gate"
    role_run_unknown = create_test_role_run(%{task_id: task_id3, role_id: unknown_role_id, status: :running})

    assert {:ok, %Task{stage_state: :awaiting_approval, error: err}, %RoleRun{status: :finished}} =
             Pipeline.settle_run(task3, role_run_unknown, %{exit_code: 0, output: "unclear"})

    assert err =~ "rol_unknown_gate ended without a clear verdict."
  end

  test "resolve_fingerprint falls back to role_run fingerprint when worktree_path is not a git repo" do
    project = create_test_project()
    role_rev = create_test_role(%{project_id: project.id, stage: :review, name: "Reviewer"})
    _role_qa = create_test_role(%{project_id: project.id, stage: :qa, name: "QA"})

    %Task{id: task_id} =
      task =
      create_test_task(%{
        project_id: project.id,
        stage: :review,
        stage_state: :running,
        worktree_path: "/tmp/nonexistent_git_dir_#{System.unique_integer([:positive])}"
      })

    role_run =
      create_test_role_run(%{
        task_id: task_id,
        role_id: role_rev.id,
        status: :running,
        stage_fingerprint_head_sha: "fallback_sha",
        stage_fingerprint_dirty_digest: "fallback_digest"
      })

    output = "Approved.\n\nVERDICT: APPROVED"

    assert {:ok, %Task{stage: :qa},
            %RoleRun{stage_fingerprint_head_sha: "fallback_sha", stage_fingerprint_dirty_digest: "fallback_digest"}} =
             Pipeline.settle_run(task, role_run, %{exit_code: 0, output: output})
  end

  test "settle_run registers detected question and preserves blocked state without advancing stage" do
    project = create_test_project()
    role = create_test_role(%{project_id: project.id, stage: :engineer})
    task = create_test_task(%{project_id: project.id, stage: :engineer, stage_state: :running})
    role_run = create_test_role_run(%{task_id: task.id, role_id: role.id, status: :running})

    output = "Working...\n[QUESTION: Which database engine?] [OPTIONS: PG, MySQL]"

    assert {:ok, %Task{stage: :engineer, stage_state: :blocked, question_id: "qst_" <> _rest = q_id},
            %RoleRun{status: :blocked_on_input, exit_code: 0}} =
             Pipeline.settle_run(task, role_run, %{exit_code: 0, output: output})

    assert byte_size(q_id) > 0
  end

  test "settle_run preserves blocked state when task was already blocked on question" do
    project = create_test_project()
    role = create_test_role(%{project_id: project.id, stage: :engineer})
    %Question{id: expected_q_id} = create_test_question(%{status: :pending})

    task =
      create_test_task(%{
        project_id: project.id,
        stage: :engineer,
        stage_state: :blocked,
        question_id: expected_q_id
      })

    role_run = create_test_role_run(%{task_id: task.id, role_id: role.id, status: :blocked_on_input})

    assert {:ok, %Task{stage: :engineer, stage_state: :blocked, question_id: ^expected_q_id},
            %RoleRun{status: :blocked_on_input, exit_code: 0}} =
             Pipeline.settle_run(task, role_run, %{exit_code: 0, output: "Exiting after ask"})
  end

  test "settle_run handles detected_question with atom and string keys and dropped question" do
    project = create_test_project()
    role = create_test_role(%{project_id: project.id, stage: :engineer})
    task1 = create_test_task(%{project_id: project.id, stage: :engineer, stage_state: :running})
    role_run1 = create_test_role_run(%{task_id: task1.id, role_id: role.id, status: :running})

    detector1 = %QuestionDetector{prompt: "Atom key question?", options: ["A", "B"]}

    assert {:ok, %Task{stage_state: :blocked, question_id: "qst_" <> _rest1 = q_id1}, %RoleRun{status: :blocked_on_input}} =
             Pipeline.settle_run(task1, role_run1, %{exit_code: 0, detected_question: detector1})

    assert byte_size(q_id1) > 0

    task2 = create_test_task(%{project_id: project.id, stage: :engineer, stage_state: :running})
    role_run2 = create_test_role_run(%{task_id: task2.id, role_id: role.id, status: :running})

    detector2 = %QuestionDetector{prompt: "String key question?", options: ["C", "D"]}

    assert {:ok, %Task{stage_state: :blocked, question_id: "qst_" <> _rest2 = q_id2}, %RoleRun{status: :blocked_on_input}} =
             Pipeline.settle_run(task2, role_run2, %{"exit_code" => 0, "detected_question" => detector2})

    assert byte_size(q_id2) > 0

    # Dropped registration when role_run has pending_answer
    task3 = create_test_task(%{project_id: project.id, stage: :engineer, stage_state: :running})

    role_run3 =
      create_test_role_run(%{
        task_id: task3.id,
        role_id: role.id,
        status: :running,
        pending_answer: "Pending"
      })

    detector3 = %QuestionDetector{prompt: "Drop this duplicate?", options: []}

    assert {:ok, %Task{stage: :review, stage_state: :queued}, %RoleRun{status: :finished}} =
             Pipeline.settle_run(task3, role_run3, %{exit_code: 0, detected_question: detector3})
  end
end
