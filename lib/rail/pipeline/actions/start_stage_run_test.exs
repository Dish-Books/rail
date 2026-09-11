defmodule Rail.Pipeline.Actions.StartStageRunTest do
  use Rail.DataCase, async: true

  import Rail.Pipeline.Utils.CaptureScratch

  alias Ecto.Adapters.SQL.Sandbox
  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Plan
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Runs
  alias Rail.Runs.FollowerSupervisor
  alias Rail.Runs.Schemas.RoleRun
  alias Rail.Runs.Schemas.Run
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    {:ok, backend} =
      Rail.Backends.create_backend(system_scope(), %{name: :claude, executable_path: "/usr/bin/true"})

    scope = system_scope()

    {:ok, workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Start Stage Workspace",
        external_id: "lin_ws_start_stage",
        token: "lin_api_token_start_stage",
        webhook_secret: "whsec_start_stage"
      })

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Start Stage Project 10701",
        github_repo: "org/start-stage-10701",
        github_installation_id: 10_701,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_start_stage_10701",
        linear_team_key: "P10701",
        default_branch: "main",
        clone_path: create_temp_git_repo(),
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    roles =
      Map.new([:product, :design, :architect, :engineer, :review, :qa, :qa_lead, :demo], fn stage ->
        {:ok, role} =
          Roles.create_role(scope, project, %{
            backend_id: backend.id,
            stage: stage,
            name: "#{stage} role",
            model: "claude-3-7-sonnet",
            system_prompt: "You are the #{stage} agent."
          })

        {stage, role}
      end)

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_start_stage_1",
      "identifier" => "SSR-1",
      "title" => "Start Stage Issue"
    })

    {:ok, issue} = Issues.capture_issue(scope, project, "Start Stage Issue")

    {:ok, task} = Pipeline.create_task(issue, :product)

    # These tests exercise the runner, not Linear publishing, so detach the issue.
    {:ok, task} = Pipeline.update_task(scope, task.id, %{issue_id: nil})

    %{backend: backend, project: project, issue: issue, task: task, roles: roles}
  end

  test "returns not_found when task ID does not exist" do
    assert {:error, :not_found} =
             Pipeline.start_stage_run("tsk_000000000000000000000000")
  end

  test "returns project_not_found when task project does not exist", %{task: _task} do
    task = %Task{id: UXID.generate!(prefix: "tsk"), project_id: "prj_000000000000000000000000"}

    assert {:error, :project_not_found} = Pipeline.start_stage_run(task)
  end

  test "fails and marks task failed when no role is configured for stage", %{task: task, roles: roles} do
    {:ok, _deleted} = Roles.delete_role(system_scope(), roles[:product])

    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")

    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :product,
        stage_state: :queued
      })

    assert {:error, :role_not_found} = Pipeline.start_stage_run(task)

    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :dispatch_failed}}

    assert %Task{stage_state: :failed, error: error_msg} = Repo.get!(Task, task_id)
    assert error_msg =~ "No role is configured"
  end

  test "fails and marks task failed when worktree creation fails", %{project: project, task: task, roles: roles} do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")
    not_a_repo = Path.join("/tmp", "not_a_repo_#{System.unique_integer([:positive])}")
    File.mkdir_p!(not_a_repo)
    on_exit(fn -> File.rm_rf(not_a_repo) end)

    _role = roles[:product]

    {:ok, _project} = Projects.update_project(system_scope(), project, %{clone_path: not_a_repo})

    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :product,
        stage_state: :queued
      })

    assert {:error, {:worktree_failed, _reason}} = Pipeline.start_stage_run(task)

    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :dispatch_failed}}

    assert %Task{stage_state: :failed, error: error_msg} = Repo.get!(Task, task_id)
    assert error_msg =~ "Failed to create worktree"
  end

  test "successfully starts stage run, initializes RoleRun, updates task, and broadcasts", %{
    backend: backend,
    task: task,
    roles: roles
  } do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")

    {:ok, %Role{id: role_id}} =
      Roles.update_role(system_scope(), roles[:product], %{
        backend_id: backend.id
      })

    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :product,
        stage_state: :queued,
        worktree_name: "test-wt-#{System.unique_integer([:positive])}"
      })

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
               allow_fun: fn pid ->
                 Sandbox.allow(Repo, self(), pid)
                 on_exit(fn -> FollowerSupervisor.stop_follower(pid) end)
               end
             )

    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :dispatched}}
    assert byte_size(wt_path) > 0
    assert byte_size(head_sha) > 0
    assert byte_size(role_run_id) > 0
    assert File.dir?(wt_path)
  end

  test "starts stage run by task ID, increments existing RoleRun attempts, and retains worktree", %{
    backend: backend,
    project: project,
    task: task,
    roles: roles
  } do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")

    {:ok, role} =
      Roles.update_role(system_scope(), roles[:product], %{
        backend_id: backend.id
      })

    wt_name = "existing-wt-#{System.unique_integer([:positive])}"
    wt_path = Path.join(project.clone_path, ".worktrees/#{wt_name}")

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :product,
        stage_state: :queued,
        worktree_name: wt_name,
        worktree_path: wt_path
      })

    {:ok, _existing_role_run} =
      Runs.create_role_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :finished,
        started_at: DateTime.utc_now(),
        attempts: 2,
        pending_answer: "clarification answered",
        attempt_log_lines: 50
      })

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
               allow_fun: fn pid ->
                 Sandbox.allow(Repo, self(), pid)
                 on_exit(fn -> FollowerSupervisor.stop_follower(pid) end)
               end
             )
  end

  test "resolves engineer role when task.is_rebasing is true", %{task: task, roles: roles} do
    %Role{id: engineer_role_id} = roles[:engineer]

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :ready_to_merge,
        stage_state: :queued,
        is_rebasing: true,
        worktree_name: "rebase-wt-#{System.unique_integer([:positive])}"
      })

    assert {:ok, %{role_run: %RoleRun{role_id: ^engineer_role_id}}} =
             Pipeline.start_stage_run(task,
               allow_fun: fn pid ->
                 Sandbox.allow(Repo, self(), pid)
                 on_exit(fn -> FollowerSupervisor.stop_follower(pid) end)
               end
             )
  end

  test "includes latest plan content and passes read_only flag for review stage", %{
    task: task,
    roles: roles
  } do
    _role = roles[:review]

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :review,
        stage_state: :queued,
        worktree_name: "review-wt-#{System.unique_integer([:positive])}"
      })

    # This test also spawns a real binary, so the plan is captured from a real scratch dir
    # rather than through File expectations.
    scratch_dir = Path.join("/tmp", "rail_plan_#{System.unique_integer([:positive])}")
    File.mkdir_p!(scratch_dir)
    File.write!(Path.join(scratch_dir, "plan.md"), "# Architectural Plan\nSteps to implement.")
    on_exit(fn -> File.rm_rf(scratch_dir) end)

    {:ok, _captured} = capture_scratch(:architect, %{task | scratch_path: scratch_dir})

    {:ok, %Plan{}} = Pipeline.get_plan(system_scope(), task)

    assert {:ok, %{task: %Task{stage_state: :running}}} =
             Pipeline.start_stage_run(task,
               allow_fun: fn pid ->
                 Sandbox.allow(Repo, self(), pid)
                 on_exit(fn -> FollowerSupervisor.stop_follower(pid) end)
               end
             )
  end

  test "handles spawn failure when runner binary cannot be executed", %{
    backend: backend,
    task: task,
    roles: roles
  } do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")

    _role = roles[:product]

    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :product,
        stage_state: :queued,
        worktree_name: "spawn-fail-wt-#{System.unique_integer([:positive])}"
      })

    missing_bin = "/path/to/definitely/missing/runner_binary_xyz"

    {:ok, _backend} =
      Rail.Backends.update_backend(system_scope(), backend, %{executable_path: missing_bin})

    assert {:error, {:spawn_failed, _reason, %Task{stage_state: :failed, error: error_msg}}} =
             Pipeline.start_stage_run(task,
               allow_fun: fn pid ->
                 Sandbox.allow(Repo, self(), pid)
                 on_exit(fn -> FollowerSupervisor.stop_follower(pid) end)
               end
             )

    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :dispatch_failed}}
    assert error_msg =~ "Failed to spawn runner"
  end

  test "invokes default on_finished callback which settles run", %{task: task, roles: roles} do
    _role = roles[:product]

    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :product,
        stage_state: :queued,
        worktree_name: "cb-wt-#{System.unique_integer([:positive])}"
      })

    test_pid = self()

    custom_cb = fn run, outcome ->
      send(test_pid, {:custom_cb_invoked, run, outcome})
      Pipeline.settle_run(task.id, run.role_run_id, outcome)
    end

    assert {:ok, %{role_run: %RoleRun{id: role_run_id}, run: run}} =
             Pipeline.start_stage_run(task,
               on_finished: custom_cb,
               allow_fun: fn pid ->
                 Sandbox.allow(Repo, self(), pid)
                 on_exit(fn -> FollowerSupervisor.stop_follower(pid) end)
               end
             )

    assert byte_size(role_run_id) > 0
    assert {:ok, %Task{id: ^task_id}, _rr} = custom_cb.(run, %{exit_code: 0})
    assert_receive {:custom_cb_invoked, ^run, %{exit_code: 0}}
  end

  test "returns not_found when task identifier is invalid type" do
    assert {:error, :not_found} = Pipeline.start_stage_run(:invalid_identifier)
  end

  test "defaults fingerprints to nil when worktree directory is not a git repo", %{
    task: task,
    roles: roles
  } do
    _role = roles[:product]
    non_git_dir = Path.join("/tmp", "rail_non_git_#{System.unique_integer([:positive])}")
    File.mkdir_p!(non_git_dir)
    on_exit(fn -> File.rm_rf(non_git_dir) end)

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :product,
        stage_state: :queued,
        worktree_path: non_git_dir
      })

    assert {:ok, %{role_run: %RoleRun{stage_fingerprint_head_sha: nil}}} =
             Pipeline.start_stage_run(task,
               allow_fun: fn pid ->
                 Sandbox.allow(Repo, self(), pid)
                 on_exit(fn -> FollowerSupervisor.stop_follower(pid) end)
               end
             )
  end

  test "executes default on_finished callback when Follower completes", %{task: task, roles: roles} do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")

    _role = roles[:product]
    {:ok, _deleted} = Roles.delete_role(system_scope(), roles[:design])

    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :product,
        stage_state: :queued,
        worktree_name: "live-follower-wt-#{System.unique_integer([:positive])}"
      })

    assert {:ok, %{task: %Task{id: ^task_id, stage_state: :running}}} =
             Pipeline.start_stage_run(task,
               allow_fun: fn pid ->
                 Sandbox.allow(Repo, self(), pid)
                 on_exit(fn -> FollowerSupervisor.stop_follower(pid) end)
               end
             )

    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :run_settled}}, 2000
    assert %Task{stage: :product, stage_state: :awaiting_approval} = Repo.get!(Task, task_id)
  end
end
