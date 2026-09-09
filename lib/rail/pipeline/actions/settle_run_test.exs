defmodule Rail.Pipeline.Actions.SettleRunTest do
  use Rail.DataCase, async: false

  alias Rail.Domain.TaskUsage
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Plan
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
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
end
