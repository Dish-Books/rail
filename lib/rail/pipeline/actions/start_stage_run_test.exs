defmodule Rail.Pipeline.Actions.StartStageRunTest do
  use Rail.DataCase, async: false

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Plan
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Roles.Schemas.Role
  alias Rail.Runs.Schemas.RoleRun
  alias Rail.Runs.Schemas.Run

  test "returns not_found when task ID does not exist" do
    assert {:error, :not_found} =
             Pipeline.start_stage_run("tsk_000000000000000000000000")
  end

  test "returns project_not_found when task project does not exist" do
    task = %Task{id: UXID.generate!(prefix: "tsk"), project_id: "prj_000000000000000000000000"}

    assert {:error, :project_not_found} = Pipeline.start_stage_run(task)
  end

  test "fails and marks task failed when no role is configured for stage" do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")
    project = create_test_project()
    %Task{id: task_id} = task = create_test_task(%{project_id: project.id, stage: :product, stage_state: :queued})

    assert {:error, {:no_role_for_stage, :product}} = Pipeline.start_stage_run(task)

    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :dispatch_failed}}

    assert %Task{stage_state: :failed, error: error_msg} = Repo.get!(Task, task_id)
    assert error_msg =~ "No role is configured"
  end

  test "fails and marks task failed when worktree creation fails" do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")
    not_a_repo = Path.join(System.tmp_dir!(), "not_a_repo_#{System.unique_integer([:positive])}")
    File.mkdir_p!(not_a_repo)
    project = create_test_project(%{clone_path: not_a_repo})
    _role = create_test_role(%{project_id: project.id, stage: :product})
    %Task{id: task_id} = task = create_test_task(%{project_id: project.id, stage: :product, stage_state: :queued})

    assert {:error, {:worktree_failed, _reason}} = Pipeline.start_stage_run(task)

    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :dispatch_failed}}

    assert %Task{stage_state: :failed, error: error_msg} = Repo.get!(Task, task_id)
    assert error_msg =~ "Failed to create worktree"
  end

  test "successfully starts stage run, initializes RoleRun, updates task, and broadcasts" do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")
    repo_dir = create_temp_git_repo()
    project = create_test_project(%{clone_path: repo_dir, default_branch: "main"})
    %Role{id: role_id} = create_test_role(%{project_id: project.id, stage: :product, cli_backend: :claude})
    scratch_dir = create_temp_scratch_dir()

    %Task{id: task_id} =
      task =
      create_test_task(%{
        project_id: project.id,
        stage: :product,
        stage_state: :queued,
        worktree_name: "test-wt-#{System.unique_integer([:positive])}"
      })

    true_bin = System.find_executable("true") || "/usr/bin/true"

    assert {:ok,
            %{
              task: %Task{stage_state: :running, worktree_path: wt_path},
              role_run: %RoleRun{
                role_id: ^role_id,
                task_id: ^task_id,
                attempts: 1,
                status: :running,
                stage_fingerprint_head_sha: head_sha
              },
              run: %Run{task_id: ^task_id, role_run_id: role_run_id}
            }} =
             Pipeline.start_stage_run(task,
               executable: true_bin,
               skip_follower: true,
               scratch_dir: scratch_dir
             )

    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :dispatched}}
    assert byte_size(wt_path) > 0
    assert byte_size(head_sha) > 0
    assert byte_size(role_run_id) > 0
    assert File.dir?(wt_path)
  end

  test "starts stage run by task ID, increments existing RoleRun attempts, and retains worktree" do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")
    repo_dir = create_temp_git_repo()
    project = create_test_project(%{clone_path: repo_dir, default_branch: "main"})
    role = create_test_role(%{project_id: project.id, stage: :product, cli_backend: :claude})
    scratch_dir = create_temp_scratch_dir()

    wt_name = "existing-wt-#{System.unique_integer([:positive])}"
    wt_path = Path.join(repo_dir, ".worktrees/#{wt_name}")

    task =
      create_test_task(%{
        project_id: project.id,
        stage: :product,
        stage_state: :queued,
        worktree_name: wt_name,
        worktree_path: wt_path
      })

    _existing_role_run =
      create_test_role_run(%{
        task_id: task.id,
        role_id: role.id,
        attempts: 2,
        pending_answer: "clarification answered",
        attempt_log_lines: 50
      })

    true_bin = System.find_executable("true") || "/usr/bin/true"

    assert {:ok,
            %{
              task: %Task{worktree_path: ^wt_path},
              role_run: %RoleRun{
                attempts: 3,
                pending_answer: nil,
                attempt_log_lines: 0
              }
            }} =
             Pipeline.start_stage_run(task.id,
               executable: true_bin,
               skip_follower: true,
               scratch_path: scratch_dir
             )
  end

  test "resolves engineer role when task.is_rebasing is true" do
    repo_dir = create_temp_git_repo()
    project = create_test_project(%{clone_path: repo_dir})
    %Role{id: engineer_role_id} = create_test_role(%{project_id: project.id, stage: :engineer})

    task =
      create_test_task(%{
        project_id: project.id,
        stage: :ready_to_merge,
        stage_state: :queued,
        is_rebasing: true,
        worktree_name: "rebase-wt-#{System.unique_integer([:positive])}"
      })

    true_bin = System.find_executable("true") || "/usr/bin/true"

    assert {:ok, %{role_run: %RoleRun{role_id: ^engineer_role_id}}} =
             Pipeline.start_stage_run(task,
               executable: true_bin,
               skip_follower: true
             )
  end

  test "includes latest plan content and passes read_only flag for review stage" do
    repo_dir = create_temp_git_repo()
    project = create_test_project(%{clone_path: repo_dir})
    _role = create_test_role(%{project_id: project.id, stage: :review})

    task =
      create_test_task(%{
        project_id: project.id,
        stage: :review,
        stage_state: :queued,
        worktree_name: "review-wt-#{System.unique_integer([:positive])}"
      })

    %Plan{} =
      create_test_plan(%{
        task_id: task.id,
        content: "# Architectural Plan\nSteps to implement."
      })

    true_bin = System.find_executable("true") || "/usr/bin/true"

    assert {:ok, %{task: %Task{stage_state: :running}}} =
             Pipeline.start_stage_run(task,
               executable: true_bin,
               skip_follower: true
             )
  end

  test "handles spawn failure when runner binary cannot be executed" do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")
    repo_dir = create_temp_git_repo()
    project = create_test_project(%{clone_path: repo_dir})
    _role = create_test_role(%{project_id: project.id, stage: :product})

    %Task{id: task_id} =
      task =
      create_test_task(%{
        project_id: project.id,
        stage: :product,
        stage_state: :queued,
        worktree_name: "spawn-fail-wt-#{System.unique_integer([:positive])}"
      })

    missing_bin = "/path/to/definitely/missing/runner_binary_xyz"

    assert {:error, {:spawn_failed, _reason, %Task{stage_state: :failed, error: error_msg}}} =
             Pipeline.start_stage_run(task,
               executable: missing_bin,
               skip_follower: true
             )

    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :dispatch_failed}}
    assert error_msg =~ "Failed to spawn runner"
  end

  test "invokes default on_finished callback which settles run" do
    repo_dir = create_temp_git_repo()
    project = create_test_project(%{clone_path: repo_dir})
    _role = create_test_role(%{project_id: project.id, stage: :product})

    %Task{id: task_id} =
      task =
      create_test_task(%{
        project_id: project.id,
        stage: :product,
        stage_state: :queued,
        worktree_name: "cb-wt-#{System.unique_integer([:positive])}"
      })

    test_pid = self()

    custom_cb = fn run, outcome ->
      send(test_pid, {:custom_cb_invoked, run, outcome})
      Pipeline.settle_run(task.id, run.role_run_id, outcome)
    end

    true_bin = System.find_executable("true") || "/usr/bin/true"

    assert {:ok, %{role_run: %RoleRun{id: role_run_id}, run: run}} =
             Pipeline.start_stage_run(task,
               executable: true_bin,
               skip_follower: true,
               on_finished: custom_cb
             )

    assert byte_size(role_run_id) > 0
    assert {:ok, %Task{id: ^task_id}, _rr} = custom_cb.(run, %{exit_code: 0})
    assert_receive {:custom_cb_invoked, ^run, %{exit_code: 0}}
  end

  test "returns not_found when task identifier is invalid type" do
    assert {:error, :not_found} = Pipeline.start_stage_run(:invalid_identifier)
  end

  test "defaults fingerprints to nil when worktree directory is not a git repo" do
    repo_dir = create_temp_git_repo()
    project = create_test_project(%{clone_path: repo_dir})
    _role = create_test_role(%{project_id: project.id, stage: :product})
    non_git_dir = create_temp_scratch_dir()

    task =
      create_test_task(%{
        project_id: project.id,
        stage: :product,
        stage_state: :queued,
        worktree_path: non_git_dir
      })

    true_bin = System.find_executable("true") || "/usr/bin/true"

    assert {:ok, %{role_run: %RoleRun{stage_fingerprint_head_sha: nil}}} =
             Pipeline.start_stage_run(task,
               executable: true_bin,
               skip_follower: true
             )
  end

  test "executes default on_finished callback when Follower completes" do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")
    repo_dir = create_temp_git_repo()
    project = create_test_project(%{clone_path: repo_dir})
    _role = create_test_role(%{project_id: project.id, stage: :product})

    %Task{id: task_id} =
      task =
      create_test_task(%{
        project_id: project.id,
        stage: :product,
        stage_state: :queued,
        worktree_name: "live-follower-wt-#{System.unique_integer([:positive])}"
      })

    true_bin = System.find_executable("true") || "/usr/bin/true"

    assert {:ok, %{task: %Task{id: ^task_id, stage_state: :running}}} =
             Pipeline.start_stage_run(task, executable: true_bin)

    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :run_settled}}, 2000
    assert %Task{stage_state: :queued, stage: :architect} = Repo.get!(Task, task_id)
  end
end
