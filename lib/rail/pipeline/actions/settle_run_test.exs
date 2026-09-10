defmodule Rail.Pipeline.Actions.SettleRunTest do
  use Rail.DataCase, async: false

  import Rail.Pipeline.Utils.Scratch
  import RailTest.Mocks.GitHub

  alias Rail.Artifacts.Schemas.Demo
  alias Rail.Artifacts.Schemas.QaReport
  alias Rail.Domain.TaskUsage
  alias Rail.Git
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Plan
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Roles.Schemas.Role
  alias Rail.Runs.QuestionDetector
  alias Rail.Runs.Schemas.RoleRun
  alias Rail.Runs.Schemas.Run
  alias RailTest.Mocks.Linear

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
      task = create_test_task(%{project_id: project.id, stage: :ready_to_merge, stage_state: :running})

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
      task = create_test_task(%{project_id: project.id, stage: :ready_to_merge, stage_state: :running})

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

  test "settles clean exit 0 for qa stage with valid manifest capturing report and advancing to qa_lead" do
    project = create_test_project()
    _ws = create_test_linear_workspace(%{project_id: project.id})
    issue = create_test_issue(%{project_id: project.id, external_id: "lin_qa_settle"})
    user = Repo.insert!(Rail.Users.Schemas.User.factory())
    %Role{id: role_qa_id} = role_qa = create_test_role(%{project_id: project.id, stage: :qa, name: "QA Tester"})
    _role_lead = create_test_role(%{project_id: project.id, stage: :qa_lead, name: "QA Lead"})

    scratch_dir =
      create_test_qa_dir(
        rows: [
          %{
            "id" => "check_1",
            "check" => "Login works",
            "result" => "pass",
            "severity" => "blocker",
            "caused_by_change" => true,
            "command" => "mix test",
            "exit_code" => 0,
            "note" => "Passed cleanly",
            "artifacts" => [
              %{
                "name" => "screenshot.png",
                "kind" => "image",
                "path" => "screenshot.png"
              }
            ]
          }
        ]
      )

    %Task{id: task_id} =
      task =
      create_test_task(%{
        project_id: project.id,
        issue_id: issue.id,
        owner_user_id: user.id,
        stage: :qa,
        stage_state: :running
      })

    %RoleRun{id: role_run_id} =
      role_run = create_test_role_run(%{task_id: task.id, role_id: role_qa.id, status: :running})

    mock_qa_uploads(1)
    Linear.mock_create_comment_success(%{"id" => "cmt_qa_settle", "body" => "QA comment"})

    output = "QA checklist completed.\n\nVERDICT: PASS"

    assert {:ok,
            %Task{
              id: ^task_id,
              stage: :qa_lead,
              stage_state: :queued,
              outstanding_reports: [^role_qa_id]
            }, %RoleRun{status: :finished, exit_code: 0}} =
             Pipeline.settle_run(task, role_run, %{exit_code: 0, output: output}, scratch_dir: scratch_dir)

    assert %QaReport{
             task_id: ^task_id,
             role_run_id: ^role_run_id,
             commit: "abc1234",
             rows: [
               %{
                 artifacts: [
                   %{url: "https://uploads.linear.app/qa_1/screenshot-1.png"}
                 ]
               }
             ]
           } = Repo.one(from q in QaReport, where: q.task_id == ^task_id)
  end

  test "settles clean exit 0 for qa stage with invalid manifest sets stage_state to failed" do
    project = create_test_project()
    role_qa = create_test_role(%{project_id: project.id, stage: :qa, name: "QA Tester"})
    scratch_dir = create_test_qa_dir(raw_manifest: "{broken_json")

    %Task{id: task_id} =
      task =
      create_test_task(%{
        project_id: project.id,
        stage: :qa,
        stage_state: :running
      })

    role_run = create_test_role_run(%{task_id: task.id, role_id: role_qa.id, status: :running})

    assert {:ok,
            %Task{
              id: ^task_id,
              stage: :qa,
              stage_state: :failed,
              error: err_msg
            }, %RoleRun{status: :finished}} =
             Pipeline.settle_run(task, role_run, %{exit_code: 0, output: "VERDICT: PASS"}, scratch_dir: scratch_dir)

    assert err_msg =~ "Failed to parse QA manifest"
  end

  test "settles clean exit 0 for qa stage with missing manifest and require_qa_manifest: true fails stage" do
    project = create_test_project()
    role_qa = create_test_role(%{project_id: project.id, stage: :qa, name: "QA Tester"})
    scratch_dir = create_temp_scratch_dir()

    %Task{id: task_id} =
      task =
      create_test_task(%{
        project_id: project.id,
        stage: :qa,
        stage_state: :running
      })

    role_run = create_test_role_run(%{task_id: task.id, role_id: role_qa.id, status: :running})

    assert {:ok,
            %Task{
              id: ^task_id,
              stage: :qa,
              stage_state: :failed,
              error: "QA manifest not found."
            }, %RoleRun{status: :finished}} =
             Pipeline.settle_run(task, role_run, %{exit_code: 0, output: "VERDICT: PASS"},
               scratch_dir: scratch_dir,
               require_qa_manifest: true
             )
  end

  test "settles clean exit 0 for qa stage resolving manifest from worktree .rail/qa, worktree qa, and root" do
    project = create_test_project()
    role_qa = create_test_role(%{project_id: project.id, stage: :qa, name: "QA Tester"})
    _role_lead = create_test_role(%{project_id: project.id, stage: :qa_lead, name: "QA Lead"})

    # Case A: Worktree with .rail/qa
    worktree_rail = create_test_qa_dir(sub_path: [".rail", "qa"], commit: "rail_sha")

    task_rail =
      create_test_task(%{
        project_id: project.id,
        stage: :qa,
        stage_state: :running,
        worktree_path: worktree_rail
      })

    role_run_rail = create_test_role_run(%{task_id: task_rail.id, role_id: role_qa.id, status: :running})

    assert {:ok, %Task{stage: :qa_lead}, %RoleRun{}} =
             Pipeline.settle_run(task_rail, role_run_rail, %{exit_code: 0, output: "VERDICT: PASS"})

    assert %QaReport{commit: "rail_sha"} = Repo.one(from q in QaReport, where: q.task_id == ^task_rail.id)

    # Case B: Worktree with qa/
    worktree_qa = create_test_qa_dir(sub_path: ["qa"], commit: "wt_qa_sha")

    task_qa =
      create_test_task(%{
        project_id: project.id,
        stage: :qa,
        stage_state: :running,
        worktree_path: worktree_qa
      })

    role_run_qa = create_test_role_run(%{task_id: task_qa.id, role_id: role_qa.id, status: :running})

    assert {:ok, %Task{stage: :qa_lead}, %RoleRun{}} =
             Pipeline.settle_run(task_qa, role_run_qa, %{exit_code: 0, output: "VERDICT: PASS"})

    assert %QaReport{commit: "wt_qa_sha"} = Repo.one(from q in QaReport, where: q.task_id == ^task_qa.id)

    # Case C: Scratch with manifest in root
    scratch_root = create_test_qa_dir(sub_path: [], commit: "root_sha")

    task_root =
      create_test_task(%{
        project_id: project.id,
        stage: :qa,
        stage_state: :running
      })

    role_run_root = create_test_role_run(%{task_id: task_root.id, role_id: role_qa.id, status: :running})

    assert {:ok, %Task{stage: :qa_lead}, %RoleRun{}} =
             Pipeline.settle_run(task_root, role_run_root, %{exit_code: 0, output: "VERDICT: PASS"},
               scratch_dir: scratch_root
             )

    assert %QaReport{commit: "root_sha"} = Repo.one(from q in QaReport, where: q.task_id == ^task_root.id)

    # Case D: Worktree with manifest in root
    worktree_root = create_test_qa_dir(sub_path: [], commit: "wt_root_sha")

    task_wt_root =
      create_test_task(%{
        project_id: project.id,
        stage: :qa,
        stage_state: :running,
        worktree_path: worktree_root
      })

    role_run_wt_root = create_test_role_run(%{task_id: task_wt_root.id, role_id: role_qa.id, status: :running})

    assert {:ok, %Task{stage: :qa_lead}, %RoleRun{}} =
             Pipeline.settle_run(task_wt_root, role_run_wt_root, %{exit_code: 0, output: "VERDICT: PASS"})

    assert %QaReport{commit: "wt_root_sha"} = Repo.one(from q in QaReport, where: q.task_id == ^task_wt_root.id)

    # Case E: scratch_path option pointing directly to manifest or subfolder
    scratch_p = create_test_qa_dir(sub_path: ["qa"], commit: "scratch_p_sha")
    task_p = create_test_task(%{project_id: project.id, stage: :qa, stage_state: :running})
    role_run_p = create_test_role_run(%{task_id: task_p.id, role_id: role_qa.id, status: :running})

    assert {:ok, %Task{stage: :qa_lead}, %RoleRun{}} =
             Pipeline.settle_run(task_p, role_run_p, %{exit_code: 0, output: "VERDICT: PASS"}, scratch_path: scratch_p)

    assert %QaReport{commit: "scratch_p_sha"} = Repo.one(from q in QaReport, where: q.task_id == ^task_p.id)
  end

  test "settles clean exit 0 for qa stage with VERDICT: FAIL captures QA report and routes to engineer" do
    project = create_test_project()
    role_eng = create_test_role(%{project_id: project.id, stage: :engineer, name: "Engineer"})
    role_qa = create_test_role(%{project_id: project.id, stage: :qa, name: "QA Tester"})
    scratch_dir = create_test_qa_dir(commit: "fail_qa_commit")

    %Task{id: task_id} =
      task =
      create_test_task(%{
        project_id: project.id,
        stage: :qa,
        stage_state: :running,
        rework_cycles: 0,
        rework_cycles_by_gate: %{}
      })

    role_run = create_test_role_run(%{task_id: task.id, role_id: role_qa.id, status: :running})

    output = "Button is broken.\n\nVERDICT: FAIL"

    assert {:ok,
            %Task{
              id: ^task_id,
              stage: :engineer,
              stage_state: :queued,
              rework_cycles: 1
            }, %RoleRun{status: :finished}} =
             Pipeline.settle_run(task, role_run, %{exit_code: 0, output: output}, scratch_dir: scratch_dir)

    assert %QaReport{commit: "fail_qa_commit"} = Repo.one(from q in QaReport, where: q.task_id == ^task_id)

    eng_run = Repo.one(from r in RoleRun, where: r.task_id == ^task_id and r.role_id == ^role_eng.id)
    assert eng_run.pending_answer =~ "Button is broken."
  end

  test "settles clean exit 0 for qa stage fails task when artifact capture fails" do
    project = create_test_project()
    _ws = create_test_linear_workspace(%{project_id: project.id})
    role_qa = create_test_role(%{project_id: project.id, stage: :qa, name: "QA Tester"})

    scratch_dir =
      create_test_qa_dir(
        rows: [
          %{
            "id" => "check_1",
            "check" => "Login works",
            "result" => "pass",
            "severity" => "blocker",
            "artifacts" => [
              %{
                "name" => "screenshot.png",
                "kind" => "image",
                "path" => "screenshot.png"
              }
            ]
          }
        ]
      )

    %Task{id: task_id} =
      task =
      create_test_task(%{
        project_id: project.id,
        stage: :qa,
        stage_state: :running
      })

    role_run = create_test_role_run(%{task_id: task.id, role_id: role_qa.id, status: :running})

    Req.Test.expect(Rail.Linear, fn conn ->
      Plug.Conn.send_resp(conn, 500, "Upload error")
    end)

    assert {:ok,
            %Task{
              id: ^task_id,
              stage: :qa,
              stage_state: :failed,
              error: err_msg
            }, %RoleRun{status: :finished}} =
             Pipeline.settle_run(task, role_run, %{exit_code: 0, output: "VERDICT: PASS"}, scratch_dir: scratch_dir)

    assert err_msg =~ "linear_api_error"
  end

  test "end-to-end pipeline flow: QA -> QA Lead materialization -> Ready to merge" do
    project = create_test_project()
    role_qa = create_test_role(%{project_id: project.id, stage: :qa, name: "QA Tester"})
    role_lead = create_test_role(%{project_id: project.id, stage: :qa_lead, name: "QA Lead"})

    qa_scratch_dir =
      create_test_qa_dir(
        commit: "flow_commit",
        rows: [
          %{
            "id" => "flow_1",
            "check" => "Flow check",
            "result" => "pass",
            "severity" => "cosmetic",
            "artifacts" => [%{"name" => "proof.txt", "kind" => "text", "text" => "FLOW PROOF TEXT"}]
          }
        ]
      )

    task =
      create_test_task(%{
        project_id: project.id,
        stage: :qa,
        stage_state: :running
      })

    role_run_qa = create_test_role_run(%{task_id: task.id, role_id: role_qa.id, status: :running})

    # Step 1: Settle QA run
    assert {:ok, %Task{stage: :qa_lead, stage_state: :queued} = task_lead_queued, _rr} =
             Pipeline.settle_run(task, role_run_qa, %{exit_code: 0, output: "VERDICT: PASS"}, scratch_dir: qa_scratch_dir)

    # Step 2: Scratch prepare for QA Lead
    lead_scratch_dir = create_temp_scratch_dir()
    assert {:ok, ^lead_scratch_dir} = prepare(task_lead_queued, lead_scratch_dir)

    # Verify materialization into lead scratch dir
    assert File.exists?(Path.join([lead_scratch_dir, "qa", "manifest.json"]))
    assert File.read!(Path.join([lead_scratch_dir, "qa", "proof.txt"])) == "FLOW PROOF TEXT"

    # Step 3: Settle QA Lead run
    role_run_lead = create_test_role_run(%{task_id: task.id, role_id: role_lead.id, status: :running})

    assert {:ok, %Task{stage: :ready_to_merge, stage_state: :awaiting_approval}, _rr2} =
             Pipeline.settle_run(task_lead_queued, role_run_lead, %{exit_code: 0, output: "VERDICT: PASS"},
               scratch_dir: lead_scratch_dir
             )
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

  test "settle_run delegates %Run{kind: :chat} and %{kind: :chat} to SettleChatTurn" do
    project = create_test_project()
    task = create_test_task(%{project_id: project.id, stage: :engineer, stage_state: :queued})
    role_run = create_test_role_run(%{task_id: task.id, status: :finished, started_at: DateTime.utc_now()})

    run_struct = %Run{kind: :chat, role_run_id: role_run.id, task_id: task.id, status: :finished}

    assert {:ok, %Task{}, %RoleRun{}} =
             Pipeline.settle_run(task, role_run, run_struct)

    assert {:ok, %Task{}, %RoleRun{}} =
             Pipeline.settle_run(task, role_run, %{kind: :chat, exit_code: 0})
  end

  test "settling clean exit 0 for rebasing task restores previous state and refreshes mergeability" do
    project = create_test_project(%{github_repo: "testorg/rebase_settle"})

    task =
      create_test_task(%{
        project_id: project.id,
        stage: :review,
        stage_state: :running,
        is_rebasing: true,
        stage_state_before_rebase: :awaiting_approval,
        pr_number: 999,
        mergeability: :conflicting,
        pr_is_draft: false
      })

    role_run = create_test_role_run(%{task_id: task.id, status: :running})

    mock_pull_request_state_success("testorg/rebase_settle", 999, mergeable: true, draft: false)

    assert {:ok,
            %Task{
              is_rebasing: false,
              stage_state: :awaiting_approval,
              stage_state_before_rebase: nil,
              mergeability: :mergeable
            }, %RoleRun{status: :finished}} =
             Pipeline.settle_run(task, role_run, %{exit_code: 0}, token: "tok_test")
  end

  test "settling non-zero exit for rebasing task preserves is_rebasing for retries" do
    project = create_test_project()

    task =
      create_test_task(%{
        project_id: project.id,
        stage: :review,
        stage_state: :running,
        is_rebasing: true,
        stage_state_before_rebase: :queued
      })

    role_run = create_test_role_run(%{task_id: task.id, status: :running, auto_retries: 0})

    assert {:ok,
            %Task{
              is_rebasing: true,
              stage_state: :failed,
              error: "Permanent error"
            }, %RoleRun{status: :finished}} =
             Pipeline.settle_run(task, role_run, %{exit_code: 1, error: "Permanent error"})
  end

  test "settling clean exit for rebasing task falls back to updated_task if refresh_mergeability fails" do
    project = create_test_project(%{github_repo: "testorg/rebase_settle_fail"})

    task =
      create_test_task(%{
        project_id: project.id,
        stage: :ready_to_merge,
        stage_state: :running,
        is_rebasing: true,
        stage_state_before_rebase: :awaiting_approval,
        mergeability: :unknown,
        pr_number: 998,
        pr_is_draft: false
      })

    role_run = create_test_role_run(%{task_id: task.id, status: :running})

    mock_pull_request_state_error("testorg/rebase_settle_fail", 998, 500, "Internal Server Error")

    assert {:ok,
            %Task{
              is_rebasing: false,
              stage_state: :awaiting_approval,
              stage_state_before_rebase: nil,
              mergeability: :unknown
            }, %RoleRun{status: :finished}} =
             Pipeline.settle_run(task, role_run, %{exit_code: 0}, token: "tok_test")
  end

  describe "settle_run at design stage" do
    test "designer run settlement fails when manifest is missing" do
      project = create_test_project()
      task = create_test_task(%{project_id: project.id, stage: :design, stage_state: :running})
      role_run = create_test_role_run(%{task_id: task.id, status: :running})

      assert {:ok, %Task{stage: :design, stage_state: :failed, error: err}, %RoleRun{status: :finished}} =
               Pipeline.settle_run(task, role_run, %{exit_code: 0})

      assert err =~ "No design manifest found at"
    end

    test "designer run settlement populates task.design when manifest is valid" do
      project = create_test_project()
      create_test_linear_workspace(%{project_id: project.id})
      worktree_dir = create_test_design_dir(canvas_url: "https://claude.ai/canvas/v1")

      task =
        create_test_task(%{project_id: project.id, stage: :design, stage_state: :running, worktree_path: worktree_dir})

      role_run = create_test_role_run(%{task_id: task.id, status: :running})

      mock_design_uploads(2)

      assert {:ok, %Task{stage: :design, stage_state: :awaiting_approval, error: nil}, %RoleRun{status: :finished}} =
               Pipeline.settle_run(task, role_run, %{exit_code: 0}, url_probe: fn _uri -> true end)

      designs = Repo.all(from d in Rail.Artifacts.Schemas.Design, where: d.task_id == ^task.id)
      assert length(designs) == 1
      assert hd(designs).canvas_url == "https://claude.ai/canvas/v1"
    end

    test "fails when manifest no longer contains outstanding pickedKey" do
      project = create_test_project()
      create_test_linear_workspace(%{project_id: project.id})

      directions = [
        %{
          "key" => "dir-other",
          "title" => "Other",
          "notes" => "Notes",
          "stillPath" => ".rail/design/dir-1.png"
        }
      ]

      worktree_dir = create_test_design_dir(version: 2, picked_key: "dir-1", directions: directions)

      task =
        create_test_task(%{project_id: project.id, stage: :design, stage_state: :running, worktree_path: worktree_dir})

      create_test_design(%{task_id: task.id, version: 1, picked_key: "dir-1"})
      role_run = create_test_role_run(%{task_id: task.id, status: :running})

      assert {:ok, %Task{stage_state: :failed, error: err}, %RoleRun{status: :finished}} =
               Pipeline.settle_run(task, role_run, %{exit_code: 0}, url_probe: fn _uri -> true end)

      assert err =~ "Manifest missing picked direction: dir-1"
    end

    test "fails when manifest version is not incremented after a pick or revision" do
      project = create_test_project()
      create_test_linear_workspace(%{project_id: project.id})
      worktree_dir = create_test_design_dir(version: 1, picked_key: "dir-1")

      task =
        create_test_task(%{project_id: project.id, stage: :design, stage_state: :running, worktree_path: worktree_dir})

      create_test_design(%{task_id: task.id, version: 1, picked_key: "dir-1"})
      role_run = create_test_role_run(%{task_id: task.id, status: :running})

      assert {:ok, %Task{stage_state: :failed, error: err}, %RoleRun{status: :finished}} =
               Pipeline.settle_run(task, role_run, %{exit_code: 0}, url_probe: fn _uri -> true end)

      assert err =~ "Manifest version must be incremented after a pick or revision."
    end

    test "fails when manifest is missing pickedKey after a pick" do
      project = create_test_project()
      create_test_linear_workspace(%{project_id: project.id})
      worktree_dir = create_test_design_dir(version: 2, picked_key: nil)

      task =
        create_test_task(%{project_id: project.id, stage: :design, stage_state: :running, worktree_path: worktree_dir})

      create_test_design(%{task_id: task.id, version: 1, picked_key: "dir-1"})
      role_run = create_test_role_run(%{task_id: task.id, status: :running})

      assert {:ok, %Task{stage_state: :failed, error: err}, %RoleRun{status: :finished}} =
               Pipeline.settle_run(task, role_run, %{exit_code: 0}, url_probe: fn _uri -> true end)

      assert err =~ "Design manifest is missing pickedKey (expected \"dir-1\")."
    end

    test "fails when manifest pickedKey does not match previously chosen direction" do
      project = create_test_project()
      create_test_linear_workspace(%{project_id: project.id})
      worktree_dir = create_test_design_dir(version: 2, picked_key: "dir-2")

      task =
        create_test_task(%{project_id: project.id, stage: :design, stage_state: :running, worktree_path: worktree_dir})

      create_test_design(%{task_id: task.id, version: 1, picked_key: "dir-1"})
      role_run = create_test_role_run(%{task_id: task.id, status: :running})

      assert {:ok, %Task{stage_state: :failed, error: err}, %RoleRun{status: :finished}} =
               Pipeline.settle_run(task, role_run, %{exit_code: 0}, url_probe: fn _uri -> true end)

      assert err =~ "Design manifest pickedKey (dir-2) does not match chosen direction (dir-1)."
    end

    test "supports settling with scratch_path and valid transition" do
      project = create_test_project()
      create_test_linear_workspace(%{project_id: project.id})
      worktree_dir = create_test_design_dir(version: 2, picked_key: "dir-1")

      task =
        create_test_task(%{project_id: project.id, stage: :design, stage_state: :running, worktree_path: nil})

      create_test_design(%{task_id: task.id, version: 1, picked_key: "dir-1"})
      role_run = create_test_role_run(%{task_id: task.id, status: :running})
      mock_design_uploads(2)

      assert {:ok, %Task{stage_state: :awaiting_approval, error: nil}, %RoleRun{status: :finished}} =
               Pipeline.settle_run(
                 task,
                 role_run,
                 %{exit_code: 0},
                 scratch_path: worktree_dir,
                 url_probe: fn _uri -> true end
               )
    end

    test "supports settling with scratch_dir and valid transition" do
      project = create_test_project()
      create_test_linear_workspace(%{project_id: project.id})
      worktree_dir = create_test_design_dir(version: 2, picked_key: "dir-1")

      task =
        create_test_task(%{project_id: project.id, stage: :design, stage_state: :running, worktree_path: nil})

      create_test_design(%{task_id: task.id, version: 1, picked_key: "dir-1"})
      role_run = create_test_role_run(%{task_id: task.id, status: :running})
      mock_design_uploads(2)

      assert {:ok, %Task{stage_state: :awaiting_approval, error: nil}, %RoleRun{status: :finished}} =
               Pipeline.settle_run(
                 task,
                 role_run,
                 %{exit_code: 0},
                 scratch_dir: worktree_dir,
                 url_probe: fn _uri -> true end
               )
    end
  end

  describe "settle_run at demo stage" do
    test "demo run settlement fails when manifest is missing" do
      project = create_test_project()
      task = create_test_task(%{project_id: project.id, stage: :demo, stage_state: :running})
      role_run = create_test_role_run(%{task_id: task.id, status: :running})

      assert {:ok, %Task{stage: :demo, stage_state: :failed, error: err}, %RoleRun{status: :finished}} =
               Pipeline.settle_run(task, role_run, %{exit_code: 0})

      assert err =~ "Demo manifest not found at"
    end

    test "demo run settlement fails when worktree moved during recording" do
      project = create_test_project()
      worktree = create_temp_git_repo()
      %{head_sha: original_sha, dirty_digest: original_digest} = Git.branch_fingerprint(worktree, ignore_rail: true)

      demo_dir = Path.join([worktree, ".rail", "demo"])
      File.mkdir_p!(demo_dir)
      File.write!(Path.join(demo_dir, "frame-1.png"), "frame")

      File.write!(
        Path.join(demo_dir, "manifest.json"),
        Jason.encode!(%{
          "version" => 1,
          "outcome" => "recorded",
          "segments" => [
            %{
              "criterionIndex" => 1,
              "criterion" => "AC 1",
              "outcome" => "recorded",
              "frames" => [%{"path" => "frame-1.png", "holdMs" => 1000, "caption" => "Step 1"}]
            }
          ]
        })
      )

      task =
        create_test_task(%{
          project_id: project.id,
          stage: :demo,
          stage_state: :running,
          worktree_path: worktree
        })

      role_run =
        create_test_role_run(%{
          task_id: task.id,
          status: :running,
          stage_fingerprint_head_sha: "prior_sha_before_move_#{original_sha}",
          stage_fingerprint_dirty_digest: original_digest
        })

      expected_err = "The worktree moved during the demo run."

      assert {:ok, %Task{stage_state: :failed, error: ^expected_err}, %RoleRun{status: :finished}} =
               Pipeline.settle_run(task, role_run, %{exit_code: 0})
    end

    test "demo run settlement fails when worktree code outside .rail/ was modified during recording" do
      project = create_test_project()
      worktree = create_temp_git_repo()
      %{head_sha: original_sha, dirty_digest: original_digest} = Git.branch_fingerprint(worktree, ignore_rail: true)

      demo_dir = Path.join([worktree, ".rail", "demo"])
      File.mkdir_p!(demo_dir)
      File.write!(Path.join(demo_dir, "frame-1.png"), "frame")

      File.write!(
        Path.join(demo_dir, "manifest.json"),
        Jason.encode!(%{
          "version" => 1,
          "outcome" => "recorded",
          "segments" => [
            %{
              "criterionIndex" => 1,
              "criterion" => "AC 1",
              "outcome" => "recorded",
              "frames" => [%{"path" => "frame-1.png", "holdMs" => 1000, "caption" => "Step 1"}]
            }
          ]
        })
      )

      File.write!(Path.join(worktree, "uncommitted.txt"), "dirtied worktree")

      task =
        create_test_task(%{
          project_id: project.id,
          stage: :demo,
          stage_state: :running,
          worktree_path: worktree
        })

      role_run =
        create_test_role_run(%{
          task_id: task.id,
          status: :running,
          stage_fingerprint_head_sha: original_sha,
          stage_fingerprint_dirty_digest: original_digest
        })

      expected_err = "Worktree code outside .rail/ was modified during recording."

      assert {:ok, %Task{stage_state: :failed, error: ^expected_err}, %RoleRun{status: :finished}} =
               Pipeline.settle_run(task, role_run, %{exit_code: 0})
    end

    test "demo run settlement succeeds when untracked frames exist in .rail/demo/" do
      project = create_test_project()
      create_test_linear_workspace(%{project_id: project.id})
      worktree = create_temp_git_repo()
      %{head_sha: original_sha, dirty_digest: original_digest} = Git.branch_fingerprint(worktree, ignore_rail: true)

      demo_dir = Path.join([worktree, ".rail", "demo"])
      File.mkdir_p!(demo_dir)
      File.write!(Path.join(demo_dir, "frame-1.png"), "frame")

      File.write!(
        Path.join(demo_dir, "manifest.json"),
        Jason.encode!(%{
          "version" => 1,
          "outcome" => "recorded",
          "segments" => [
            %{
              "criterionIndex" => 1,
              "criterion" => "AC 1",
              "outcome" => "recorded",
              "frames" => [%{"path" => "frame-1.png", "holdMs" => 1000, "caption" => "Step 1"}]
            }
          ]
        })
      )

      mock_demo_uploads(1)

      task =
        create_test_task(%{
          project_id: project.id,
          stage: :demo,
          stage_state: :running,
          worktree_path: worktree
        })

      role_run =
        create_test_role_run(%{
          task_id: task.id,
          status: :running,
          stage_fingerprint_head_sha: original_sha,
          stage_fingerprint_dirty_digest: original_digest
        })

      assert {:ok, %Task{stage: :ready_to_merge, stage_state: :awaiting_approval, error: nil},
              %RoleRun{status: :finished}} =
               Pipeline.settle_run(task, role_run, %{exit_code: 0})

      assert %Demo{version: 1, outcome: "recorded", stale: false} =
               Repo.one(from d in Demo, where: d.task_id == ^task.id)
    end

    test "recorded outcome increments version, captures demo, and advances to ready_to_merge" do
      project = create_test_project()
      create_test_linear_workspace(%{project_id: project.id})
      worktree_dir = create_test_demo_dir(version: 2)

      task =
        create_test_task(%{
          project_id: project.id,
          stage: :demo,
          stage_state: :running,
          worktree_path: worktree_dir
        })

      create_test_demo(%{task_id: task.id, version: 1, outcome: "recorded", stale: true})
      role_run = create_test_role_run(%{task_id: task.id, status: :running})
      mock_demo_uploads(1)

      assert {:ok, %Task{stage: :ready_to_merge, stage_state: :awaiting_approval, error: nil},
              %RoleRun{status: :finished}} =
               Pipeline.settle_run(task, role_run, %{exit_code: 0})

      demos = Repo.all(from d in Demo, where: d.task_id == ^task.id, order_by: [asc: d.version])
      assert length(demos) == 2
      latest = List.last(demos)
      assert latest.version == 2
      assert latest.outcome == "recorded"
      refute latest.stale
    end

    test "declined outcome records demo with note and advances to ready_to_merge" do
      project = create_test_project()
      worktree_dir = create_test_demo_dir(version: 1, outcome: "declined", note: "Not suitable for demo recording")

      task =
        create_test_task(%{
          project_id: project.id,
          stage: :demo,
          stage_state: :running,
          worktree_path: worktree_dir
        })

      role_run = create_test_role_run(%{task_id: task.id, status: :running})

      assert {:ok, %Task{stage: :ready_to_merge, stage_state: :awaiting_approval, error: nil},
              %RoleRun{status: :finished}} =
               Pipeline.settle_run(task, role_run, %{exit_code: 0})

      assert %Demo{version: 1, outcome: "declined", note: "Not suitable for demo recording"} =
               Repo.one(from d in Demo, where: d.task_id == ^task.id)
    end

    test "failed outcome records failure and stops at demo failed" do
      project = create_test_project()
      worktree_dir = create_test_demo_dir(version: 1, outcome: "failed", note: "UI timed out during demo recording")

      task =
        create_test_task(%{
          project_id: project.id,
          stage: :demo,
          stage_state: :running,
          worktree_path: worktree_dir
        })

      role_run = create_test_role_run(%{task_id: task.id, status: :running})

      assert {:ok, %Task{stage: :demo, stage_state: :failed, error: err}, %RoleRun{status: :finished}} =
               Pipeline.settle_run(task, role_run, %{exit_code: 0})

      assert err =~ "UI timed out during demo recording"

      assert %Demo{version: 1, outcome: "failed", note: "UI timed out during demo recording"} =
               Repo.one(from d in Demo, where: d.task_id == ^task.id)
    end

    test "demo run non-zero exit code fails stage" do
      project = create_test_project()
      task = create_test_task(%{project_id: project.id, stage: :demo, stage_state: :running})
      role_run = create_test_role_run(%{task_id: task.id, status: :running, auto_retries: 0})

      assert {:ok, %Task{stage: :demo, stage_state: :failed, error: "Demo process crashed"}, %RoleRun{status: :finished}} =
               Pipeline.settle_run(task, role_run, %{exit_code: 1, error: "Demo process crashed"})
    end

    test "supports settling demo with scratch_path and scratch_dir options" do
      project = create_test_project()
      create_test_linear_workspace(%{project_id: project.id})
      scratch_1 = create_test_demo_dir(version: 1)
      scratch_2 = create_test_demo_dir(version: 2)

      task1 = create_test_task(%{project_id: project.id, stage: :demo, stage_state: :running, worktree_path: nil})
      role_run1 = create_test_role_run(%{task_id: task1.id, status: :running})
      mock_demo_uploads(1)

      assert {:ok, %Task{stage: :ready_to_merge, stage_state: :awaiting_approval}, %RoleRun{status: :finished}} =
               Pipeline.settle_run(task1, role_run1, %{exit_code: 0}, scratch_path: scratch_1)

      task2 = create_test_task(%{project_id: project.id, stage: :demo, stage_state: :running, worktree_path: nil})
      role_run2 = create_test_role_run(%{task_id: task2.id, status: :running})
      mock_demo_uploads(1)

      assert {:ok, %Task{stage: :ready_to_merge, stage_state: :awaiting_approval}, %RoleRun{status: :finished}} =
               Pipeline.settle_run(task2, role_run2, %{exit_code: 0}, scratch_dir: scratch_2)
    end

    test "fails when manifest format is invalid during capture" do
      project = create_test_project()
      scratch_dir = create_temp_scratch_dir()
      demo_dir = Path.join([scratch_dir, ".rail", "demo"])
      File.mkdir_p!(demo_dir)

      File.write!(
        Path.join(demo_dir, "manifest.json"),
        Jason.encode!(%{"version" => 1, "outcome" => "recorded"})
      )

      task = create_test_task(%{project_id: project.id, stage: :demo, stage_state: :running, worktree_path: nil})
      role_run = create_test_role_run(%{task_id: task.id, status: :running})

      assert {:ok, %Task{stage_state: :failed, error: err}, %RoleRun{status: :finished}} =
               Pipeline.settle_run(task, role_run, %{exit_code: 0}, scratch_dir: scratch_dir)

      assert err =~ "segments"
    end

    test "fails when capture_demo fails during demo settlement" do
      project = create_test_project()
      create_test_linear_workspace(%{project_id: project.id})
      scratch_dir = create_temp_scratch_dir()
      demo_dir = Path.join([scratch_dir, ".rail", "demo"])
      File.mkdir_p!(demo_dir)
      frame = Path.join(demo_dir, "frame-1.png")
      File.write!(frame, "frame")

      File.write!(
        Path.join(demo_dir, "manifest.json"),
        Jason.encode!(%{
          "version" => 1,
          "outcome" => "recorded",
          "segments" => [
            %{
              "criterionIndex" => 1,
              "criterion" => "AC 1",
              "outcome" => "recorded",
              "frames" => [%{"path" => "frame-1.png", "holdMs" => 1000, "caption" => "Step 1"}]
            }
          ]
        })
      )

      Linear.mock_file_upload_success(put_status: 500)

      task = create_test_task(%{project_id: project.id, stage: :demo, stage_state: :running, worktree_path: nil})
      role_run = create_test_role_run(%{task_id: task.id, status: :running})

      assert {:ok, %Task{stage_state: :failed, error: err}, %RoleRun{status: :finished}} =
               Pipeline.settle_run(task, role_run, %{exit_code: 0}, scratch_dir: scratch_dir)

      assert byte_size(err) > 0
    end

    test "resolves criteria from task description and handles nonexistent worktree path" do
      project = create_test_project()
      create_test_linear_workspace(%{project_id: project.id})
      scratch_dir = create_test_demo_dir(version: 1, criterion: "First criterion")

      task =
        create_test_task(%{
          project_id: project.id,
          stage: :demo,
          stage_state: :running,
          description: "Feature details\n\n## Acceptance criteria\n- First criterion",
          worktree_path: "/tmp/nonexistent_wt_#{System.unique_integer([:positive])}"
        })

      role_run =
        create_test_role_run(%{
          task_id: task.id,
          status: :running,
          stage_fingerprint_head_sha: "head_fallback",
          stage_fingerprint_dirty_digest: "digest_fallback"
        })

      mock_demo_uploads(1)

      assert {:ok, %Task{stage: :ready_to_merge, stage_state: :awaiting_approval}, %RoleRun{status: :finished}} =
               Pipeline.settle_run(task, role_run, %{exit_code: 0}, scratch_dir: scratch_dir)
    end

    test "handles non-git worktree directory gracefully during demo settlement" do
      project = create_test_project()
      create_test_linear_workspace(%{project_id: project.id})
      scratch_dir = create_temp_scratch_dir()
      demo_dir = Path.join([scratch_dir, ".rail", "demo"])
      File.mkdir_p!(demo_dir)
      frame = Path.join(demo_dir, "frame-1.png")
      File.write!(frame, "frame")

      File.write!(
        Path.join(demo_dir, "manifest.json"),
        Jason.encode!(%{
          "version" => 1,
          "outcome" => "recorded",
          "segments" => [
            %{
              "criterionIndex" => 1,
              "criterion" => "AC 1",
              "outcome" => "recorded",
              "frames" => [%{"path" => "frame-1.png", "holdMs" => 1000, "caption" => "Step 1"}]
            }
          ]
        })
      )

      task =
        create_test_task(%{
          project_id: project.id,
          stage: :demo,
          stage_state: :running,
          worktree_path: scratch_dir
        })

      role_run =
        create_test_role_run(%{
          task_id: task.id,
          status: :running,
          stage_fingerprint_head_sha: "some_sha",
          stage_fingerprint_dirty_digest: "some_digest"
        })

      mock_demo_uploads(1)

      assert {:ok, %Task{stage: :ready_to_merge, stage_state: :awaiting_approval}, %RoleRun{status: :finished}} =
               Pipeline.settle_run(task, role_run, %{exit_code: 0})
    end

    test "resolves demo target from scratch_dir when task has no worktree_path" do
      project = create_test_project()
      create_test_linear_workspace(%{project_id: project.id})
      task = create_test_task(%{project_id: project.id, stage: :demo, stage_state: :running, worktree_path: nil})
      role_run = create_test_role_run(%{task_id: task.id, status: :running})

      scratch_dir = Path.join([System.tmp_dir!(), "rail", task.project_id, "scratch", task.id])
      demo_dir = Path.join([scratch_dir, "demo"])
      File.mkdir_p!(demo_dir)
      frame = Path.join(demo_dir, "frame-1.png")
      File.write!(frame, "frame")

      File.write!(
        Path.join(demo_dir, "manifest.json"),
        Jason.encode!(%{
          "version" => 1,
          "outcome" => "recorded",
          "segments" => [
            %{
              "criterionIndex" => 1,
              "criterion" => "AC 1",
              "outcome" => "recorded",
              "frames" => [%{"path" => "frame-1.png", "holdMs" => 1000, "caption" => "Step 1"}]
            }
          ]
        })
      )

      mock_demo_uploads(1)

      assert {:ok, %Task{stage: :ready_to_merge, stage_state: :awaiting_approval}, %RoleRun{status: :finished}} =
               Pipeline.settle_run(task, role_run, %{exit_code: 0})
    end

    test "supports explicit criteria in opts when settling demo" do
      project = create_test_project()
      create_test_linear_workspace(%{project_id: project.id})
      worktree_dir = create_test_demo_dir(version: 1, criterion: "Explicit criterion")

      task =
        create_test_task(%{
          project_id: project.id,
          stage: :demo,
          stage_state: :running,
          worktree_path: worktree_dir
        })

      role_run = create_test_role_run(%{task_id: task.id, status: :running})
      mock_demo_uploads(1)

      assert {:ok, %Task{stage: :ready_to_merge}, %RoleRun{status: :finished}} =
               Pipeline.settle_run(task, role_run, %{exit_code: 0}, criteria: ["Explicit criterion"])
    end
  end
end
