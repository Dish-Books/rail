defmodule Rail.Pipeline.Actions.SettleDemoRunTest do
  use Rail.DataCase, async: true

  import RailTest.PipelineHelpers

  alias Rail.Artifacts
  alias Rail.Artifacts.Schemas.Demo
  alias Rail.Git
  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Runs
  alias Rail.Runs.Schemas.RoleRun
  alias Rail.Runs.Schemas.Run
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    {:ok, backend} =
      Rail.Backends.create_backend(system_scope(), %{name: :claude, executable_path: "/usr/bin/true"})

    scope = system_scope()

    {:ok, workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Settle Demo Workspace",
        external_id: "lin_ws_settle_demo",
        token: "lin_api_token_settle_demo",
        webhook_secret: "whsec_settle_demo"
      })

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Settle Demo Project 14608",
        github_repo: "org/settle-demo-14608",
        github_installation_id: 14_608,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_settle_demo_14608",
        linear_team_key: "P14608",
        default_branch: "main",
        clone_path: "/tmp/repos/settle-demo-14608",
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
      "id" => "lin_settle_demo_1",
      "identifier" => "S14608-1",
      "title" => "Settle Demo Issue"
    })

    {:ok, issue} = Issues.capture_issue(scope, project, "Settle Demo Issue")

    {:ok, task} = Pipeline.create_task(issue, :product)

    # These tests exercise stage transitions, not Linear publishing.
    {:ok, task} = Pipeline.update_task(scope, task.id, %{issue_id: nil})

    %{backend: backend, project: project, issue: issue, task: task, roles: roles}
  end

  describe "settle_run at demo stage" do
    test "demo run settlement fails when manifest is missing", %{task: task, roles: roles} do
      {:ok, task} =
        Pipeline.update_task(system_scope(), task.id, %{
          stage: :demo,
          stage_state: :running
        })

      {:ok, role_run} =
        Runs.create_role_run(%{
          task_id: task.id,
          role_id: roles[:engineer].id,
          conversation_id: "sess_fixture",
          status: :running,
          started_at: DateTime.utc_now()
        })

      run =
        %Run{}
        |> Run.changeset(%{
          role_run_id: role_run.id,
          task_id: role_run.task_id,
          kind: :stage,
          stream_path: "/tmp/settle_demo/#{role_run.id}.ndjson",
          node: to_string(Node.self()),
          status: :running,
          started_at: DateTime.utc_now()
        })
        |> Repo.insert!()

      {:ok, _settled_task, _settled_role_run} = Pipeline.settle_run(run, %{exit_code: 0})

      assert {:ok, %Task{stage: :demo, stage_state: :failed, error: err}, %RoleRun{status: :finished}} =
               Pipeline.settle_demo_run(run)

      assert err =~ "Demo manifest not found at"
    end

    test "demo run settlement fails when worktree moved during recording", %{task: task, roles: roles} do
      worktree = create_temp_git_repo()
      %{head_sha: original_sha, dirty_digest: original_digest} = Git.branch_fingerprint(worktree)

      demo_dir = Path.join(worktree, "demo")
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

      {:ok, task} =
        Pipeline.update_task(system_scope(), task.id, %{
          stage: :demo,
          stage_state: :running,
          worktree_path: worktree,
          scratch_path: worktree
        })

      {:ok, role_run} =
        Runs.create_role_run(%{
          task_id: task.id,
          role_id: roles[:engineer].id,
          conversation_id: "sess_fixture",
          status: :running,
          started_at: DateTime.utc_now(),
          stage_fingerprint_head_sha: "prior_sha_before_move_#{original_sha}",
          stage_fingerprint_dirty_digest: original_digest
        })

      expected_err = "The worktree moved during the demo run."

      run =
        %Run{}
        |> Run.changeset(%{
          role_run_id: role_run.id,
          task_id: role_run.task_id,
          kind: :stage,
          stream_path: "/tmp/settle_demo/#{role_run.id}.ndjson",
          node: to_string(Node.self()),
          status: :running,
          started_at: DateTime.utc_now()
        })
        |> Repo.insert!()

      {:ok, _settled_task, _settled_role_run} = Pipeline.settle_run(run, %{exit_code: 0})

      assert {:ok, %Task{stage_state: :failed, error: ^expected_err}, %RoleRun{status: :finished}} =
               Pipeline.settle_demo_run(run)
    end

    test "demo run settlement fails when worktree code outside .rail/ was modified during recording", %{
      task: task,
      roles: roles
    } do
      worktree = create_temp_git_repo()
      %{head_sha: original_sha, dirty_digest: original_digest} = Git.branch_fingerprint(worktree)

      demo_dir = Path.join(worktree, "demo")
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

      {:ok, task} =
        Pipeline.update_task(system_scope(), task.id, %{
          stage: :demo,
          stage_state: :running,
          worktree_path: worktree,
          scratch_path: worktree
        })

      {:ok, role_run} =
        Runs.create_role_run(%{
          task_id: task.id,
          role_id: roles[:engineer].id,
          conversation_id: "sess_fixture",
          status: :running,
          started_at: DateTime.utc_now(),
          stage_fingerprint_head_sha: original_sha,
          stage_fingerprint_dirty_digest: original_digest
        })

      expected_err = "Worktree code outside .rail/ was modified during recording."

      run =
        %Run{}
        |> Run.changeset(%{
          role_run_id: role_run.id,
          task_id: role_run.task_id,
          kind: :stage,
          stream_path: "/tmp/settle_demo/#{role_run.id}.ndjson",
          node: to_string(Node.self()),
          status: :running,
          started_at: DateTime.utc_now()
        })
        |> Repo.insert!()

      {:ok, _settled_task, _settled_role_run} = Pipeline.settle_run(run, %{exit_code: 0})

      assert {:ok, %Task{stage_state: :failed, error: ^expected_err}, %RoleRun{status: :finished}} =
               Pipeline.settle_demo_run(run)
    end

    test "demo run settlement succeeds with the recording written to scratch", %{task: task, roles: roles} do
      {:ok, _workspace} =
        Projects.upsert_linear_workspace(system_scope(), %{
          name: "Settle Run Workspace 14609",
          external_id: "lin_ws_settle_run_14609",
          token: "lin_api_token_settle_run_14609",
          webhook_secret: "whsec_settle_run_14609"
        })

      worktree = create_temp_git_repo()
      %{head_sha: original_sha, dirty_digest: original_digest} = Git.branch_fingerprint(worktree)

      # Scratch sits outside the worktree, so recording leaves the tree untouched.
      scratch = Path.join("/tmp", "rail_demo_scratch_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(scratch) end)
      demo_dir = Path.join(scratch, "demo")
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

      {:ok, task} =
        Pipeline.update_task(system_scope(), task.id, %{
          stage: :demo,
          stage_state: :running,
          worktree_path: worktree,
          scratch_path: scratch
        })

      {:ok, role_run} =
        Runs.create_role_run(%{
          task_id: task.id,
          role_id: roles[:engineer].id,
          conversation_id: "sess_fixture",
          status: :running,
          started_at: DateTime.utc_now(),
          stage_fingerprint_head_sha: original_sha,
          stage_fingerprint_dirty_digest: original_digest
        })

      run =
        %Run{}
        |> Run.changeset(%{
          role_run_id: role_run.id,
          task_id: role_run.task_id,
          kind: :stage,
          stream_path: "/tmp/settle_demo/#{role_run.id}.ndjson",
          node: to_string(Node.self()),
          status: :running,
          started_at: DateTime.utc_now()
        })
        |> Repo.insert!()

      {:ok, _settled_task, _settled_role_run} = Pipeline.settle_run(run, %{exit_code: 0})

      assert {:ok, %Task{stage: :ready_to_merge, stage_state: :awaiting_approval, error: nil},
              %RoleRun{status: :finished}} =
               Pipeline.settle_demo_run(run)

      assert %Demo{version: 1, outcome: "recorded", stale: false} =
               Repo.one(from d in Demo, where: d.task_id == ^task.id)
    end

    test "recorded outcome increments version, captures demo, and advances to ready_to_merge", %{task: task, roles: roles} do
      {:ok, _workspace} =
        Projects.upsert_linear_workspace(system_scope(), %{
          name: "Settle Run Workspace 14610",
          external_id: "lin_ws_settle_run_14610",
          token: "lin_api_token_settle_run_14610",
          webhook_secret: "whsec_settle_run_14610"
        })

      worktree_dir = Path.join("/tmp", "rail_demo_wt_#{System.unique_integer([:positive])}")
      demo_dir = Path.join(worktree_dir, "demo")
      File.mkdir_p!(demo_dir)
      on_exit(fn -> File.rm_rf(worktree_dir) end)

      File.write!(Path.join(demo_dir, "frame-1.png"), "fake demo frame content 1")

      File.write!(
        Path.join(demo_dir, "manifest.json"),
        Jason.encode!(%{
          "version" => 2,
          "outcome" => "recorded",
          "note" => nil,
          "segments" => [
            %{
              "criterionIndex" => 1,
              "criterion" => "Feature works as expected",
              "outcome" => "recorded",
              "frames" => [%{"path" => "frame-1.png", "holdMs" => 1000, "caption" => "Step 1"}]
            }
          ]
        })
      )

      {:ok, task} =
        Pipeline.update_task(system_scope(), task.id, %{
          stage: :demo,
          stage_state: :running,
          worktree_path: worktree_dir,
          scratch_path: worktree_dir
        })

      # A stale v1 demo already exists; settling captures the v2 manifest on disk.
      demo_manifest_path = Path.join(demo_dir, "manifest.json")
      final_demo_manifest = File.read!(demo_manifest_path)
      base_demo_manifest = Jason.decode!(final_demo_manifest)

      File.write!(demo_manifest_path, Jason.encode!(%{base_demo_manifest | "version" => 1}))

      mock_demo_uploads(1)

      {:ok, _demo} = Artifacts.capture_demo(system_scope(), task, worktree_dir)

      {:ok, _demo} = Artifacts.mark_demo_stale(system_scope(), task)

      File.write!(demo_manifest_path, final_demo_manifest)

      {:ok, role_run} =
        Runs.create_role_run(%{
          task_id: task.id,
          role_id: roles[:engineer].id,
          conversation_id: "sess_fixture",
          status: :running,
          started_at: DateTime.utc_now()
        })

      mock_demo_uploads(1)

      run =
        %Run{}
        |> Run.changeset(%{
          role_run_id: role_run.id,
          task_id: role_run.task_id,
          kind: :stage,
          stream_path: "/tmp/settle_demo/#{role_run.id}.ndjson",
          node: to_string(Node.self()),
          status: :running,
          started_at: DateTime.utc_now()
        })
        |> Repo.insert!()

      {:ok, _settled_task, _settled_role_run} = Pipeline.settle_run(run, %{exit_code: 0})

      assert {:ok, %Task{stage: :ready_to_merge, stage_state: :awaiting_approval, error: nil},
              %RoleRun{status: :finished}} =
               Pipeline.settle_demo_run(run)

      demos = Repo.all(from d in Demo, where: d.task_id == ^task.id, order_by: [asc: d.version])
      assert length(demos) == 2
      latest = List.last(demos)
      assert latest.version == 2
      assert latest.outcome == "recorded"
      refute latest.stale
    end

    test "declined outcome records demo with note and advances to ready_to_merge", %{task: task, roles: roles} do
      worktree_dir = Path.join("/tmp", "rail_demo_wt_#{System.unique_integer([:positive])}")
      demo_dir = Path.join(worktree_dir, "demo")
      File.mkdir_p!(demo_dir)
      on_exit(fn -> File.rm_rf(worktree_dir) end)

      File.write!(Path.join(demo_dir, "frame-1.png"), "fake demo frame content 1")

      File.write!(
        Path.join(demo_dir, "manifest.json"),
        Jason.encode!(%{
          "version" => 1,
          "outcome" => "declined",
          "note" => "Not suitable for demo recording",
          "segments" => []
        })
      )

      {:ok, task} =
        Pipeline.update_task(system_scope(), task.id, %{
          stage: :demo,
          stage_state: :running,
          worktree_path: worktree_dir,
          scratch_path: worktree_dir
        })

      {:ok, role_run} =
        Runs.create_role_run(%{
          task_id: task.id,
          role_id: roles[:engineer].id,
          conversation_id: "sess_fixture",
          status: :running,
          started_at: DateTime.utc_now()
        })

      run =
        %Run{}
        |> Run.changeset(%{
          role_run_id: role_run.id,
          task_id: role_run.task_id,
          kind: :stage,
          stream_path: "/tmp/settle_demo/#{role_run.id}.ndjson",
          node: to_string(Node.self()),
          status: :running,
          started_at: DateTime.utc_now()
        })
        |> Repo.insert!()

      {:ok, _settled_task, _settled_role_run} = Pipeline.settle_run(run, %{exit_code: 0})

      assert {:ok, %Task{stage: :ready_to_merge, stage_state: :awaiting_approval, error: nil},
              %RoleRun{status: :finished}} =
               Pipeline.settle_demo_run(run)

      assert %Demo{version: 1, outcome: "declined", note: "Not suitable for demo recording"} =
               Repo.one(from d in Demo, where: d.task_id == ^task.id)
    end

    test "failed outcome records failure and stops at demo failed", %{task: task, roles: roles} do
      worktree_dir = Path.join("/tmp", "rail_demo_wt_#{System.unique_integer([:positive])}")
      demo_dir = Path.join(worktree_dir, "demo")
      File.mkdir_p!(demo_dir)
      on_exit(fn -> File.rm_rf(worktree_dir) end)

      File.write!(Path.join(demo_dir, "frame-1.png"), "fake demo frame content 1")

      File.write!(
        Path.join(demo_dir, "manifest.json"),
        Jason.encode!(%{
          "version" => 1,
          "outcome" => "failed",
          "note" => "UI timed out during demo recording",
          "segments" => []
        })
      )

      {:ok, task} =
        Pipeline.update_task(system_scope(), task.id, %{
          stage: :demo,
          stage_state: :running,
          worktree_path: worktree_dir,
          scratch_path: worktree_dir
        })

      {:ok, role_run} =
        Runs.create_role_run(%{
          task_id: task.id,
          role_id: roles[:engineer].id,
          conversation_id: "sess_fixture",
          status: :running,
          started_at: DateTime.utc_now()
        })

      run =
        %Run{}
        |> Run.changeset(%{
          role_run_id: role_run.id,
          task_id: role_run.task_id,
          kind: :stage,
          stream_path: "/tmp/settle_demo/#{role_run.id}.ndjson",
          node: to_string(Node.self()),
          status: :running,
          started_at: DateTime.utc_now()
        })
        |> Repo.insert!()

      {:ok, _settled_task, _settled_role_run} = Pipeline.settle_run(run, %{exit_code: 0})

      assert {:ok, %Task{stage: :demo, stage_state: :failed, error: err}, %RoleRun{status: :finished}} =
               Pipeline.settle_demo_run(run)

      assert err =~ "UI timed out during demo recording"

      assert %Demo{version: 1, outcome: "failed", note: "UI timed out during demo recording"} =
               Repo.one(from d in Demo, where: d.task_id == ^task.id)
    end

    test "demo run non-zero exit code fails stage", %{task: task, roles: roles} do
      {:ok, task} =
        Pipeline.update_task(system_scope(), task.id, %{
          stage: :demo,
          stage_state: :running
        })

      {:ok, role_run} =
        Runs.create_role_run(%{
          task_id: task.id,
          role_id: roles[:engineer].id,
          conversation_id: "sess_fixture",
          status: :running,
          started_at: DateTime.utc_now(),
          auto_retries: 0
        })

      run =
        %Run{}
        |> Run.changeset(%{
          role_run_id: role_run.id,
          task_id: role_run.task_id,
          kind: :stage,
          stream_path: "/tmp/settle_demo/#{role_run.id}.ndjson",
          node: to_string(Node.self()),
          status: :running,
          started_at: DateTime.utc_now()
        })
        |> Repo.insert!()

      {:ok, _settled_task, _settled_role_run} = Pipeline.settle_run(run, %{exit_code: 1, error: "Demo process crashed"})

      assert {:ok, %Task{stage: :demo, stage_state: :failed, error: "Demo process crashed"}, %RoleRun{status: :finished}} =
               Pipeline.settle_demo_run(run)
    end

    test "supports settling demo with scratch_path and scratch_dir options", %{project: project, task: task, roles: roles} do
      {:ok, _workspace} =
        Projects.upsert_linear_workspace(system_scope(), %{
          name: "Settle Run Workspace 14611",
          external_id: "lin_ws_settle_run_14611",
          token: "lin_api_token_settle_run_14611",
          webhook_secret: "whsec_settle_run_14611"
        })

      scratch_1 = Path.join("/tmp", "rail_demo_wt_#{System.unique_integer([:positive])}")
      demo_dir = Path.join(scratch_1, "demo")
      File.mkdir_p!(demo_dir)
      on_exit(fn -> File.rm_rf(scratch_1) end)

      File.write!(Path.join(demo_dir, "frame-1.png"), "fake demo frame content 1")

      File.write!(
        Path.join(demo_dir, "manifest.json"),
        Jason.encode!(%{
          "version" => 1,
          "outcome" => "recorded",
          "note" => nil,
          "segments" => [
            %{
              "criterionIndex" => 1,
              "criterion" => "Feature works as expected",
              "outcome" => "recorded",
              "frames" => [%{"path" => "frame-1.png", "holdMs" => 1000, "caption" => "Step 1"}]
            }
          ]
        })
      )

      scratch_2 = Path.join("/tmp", "rail_demo_wt_#{System.unique_integer([:positive])}")
      demo_dir = Path.join(scratch_2, "demo")
      File.mkdir_p!(demo_dir)
      on_exit(fn -> File.rm_rf(scratch_2) end)

      File.write!(Path.join(demo_dir, "frame-1.png"), "fake demo frame content 1")

      File.write!(
        Path.join(demo_dir, "manifest.json"),
        Jason.encode!(%{
          "version" => 2,
          "outcome" => "recorded",
          "note" => nil,
          "segments" => [
            %{
              "criterionIndex" => 1,
              "criterion" => "Feature works as expected",
              "outcome" => "recorded",
              "frames" => [%{"path" => "frame-1.png", "holdMs" => 1000, "caption" => "Step 1"}]
            }
          ]
        })
      )

      {:ok, task1} =
        Pipeline.update_task(system_scope(), task.id, %{
          stage: :demo,
          stage_state: :running,
          worktree_path: "/tmp/rail-removed-worktree"
        })

      {:ok, role_run1} =
        Runs.create_role_run(%{
          task_id: task1.id,
          role_id: roles[:engineer].id,
          conversation_id: "sess_fixture",
          status: :running,
          started_at: DateTime.utc_now()
        })

      mock_demo_uploads(1)

      {:ok, _persisted} = Pipeline.update_task(system_scope(), task1.id, %{scratch_path: scratch_1})

      run =
        %Run{}
        |> Run.changeset(%{
          role_run_id: role_run1.id,
          task_id: role_run1.task_id,
          kind: :stage,
          stream_path: "/tmp/settle_demo/#{role_run1.id}-#{System.unique_integer([:positive])}.ndjson",
          node: to_string(Node.self()),
          status: :running,
          started_at: DateTime.utc_now()
        })
        |> Repo.insert!()

      {:ok, _st, _srr} = Pipeline.settle_run(run, %{exit_code: 0})

      assert {:ok, %Task{stage: :ready_to_merge, stage_state: :awaiting_approval}, %RoleRun{status: :finished}} =
               Pipeline.settle_demo_run(run)

      LinearMock.mock_create_issue_success(%{
        "id" => "lin_task_settle_run_14511",
        "identifier" => "TSK-14511",
        "title" => "Task 14511"
      })

      {:ok, issue_14511} = Issues.capture_issue(system_scope(), project, "Task 14511")

      {:ok, task2} = Pipeline.create_task(issue_14511, :product)

      {:ok, task2} = Pipeline.update_task(system_scope(), task2.id, %{issue_id: nil})

      {:ok, task2} =
        Pipeline.update_task(system_scope(), task2.id, %{
          stage: :demo,
          stage_state: :running,
          worktree_path: "/tmp/rail-removed-worktree"
        })

      {:ok, role_run2} =
        Runs.create_role_run(%{
          task_id: task2.id,
          role_id: roles[:engineer].id,
          conversation_id: "sess_fixture",
          status: :running,
          started_at: DateTime.utc_now()
        })

      mock_demo_uploads(1)

      {:ok, _persisted} = Pipeline.update_task(system_scope(), task2.id, %{scratch_path: scratch_2})

      run_2 =
        %Run{}
        |> Run.changeset(%{
          role_run_id: role_run2.id,
          task_id: role_run2.task_id,
          kind: :stage,
          stream_path: "/tmp/settle_demo/#{role_run2.id}-#{System.unique_integer([:positive])}.ndjson",
          node: to_string(Node.self()),
          status: :running,
          started_at: DateTime.utc_now()
        })
        |> Repo.insert!()

      {:ok, _st, _srr} = Pipeline.settle_run(run_2, %{exit_code: 0})

      assert {:ok, %Task{stage: :ready_to_merge, stage_state: :awaiting_approval}, %RoleRun{status: :finished}} =
               Pipeline.settle_demo_run(run_2)
    end

    test "fails when manifest format is invalid during capture", %{task: task, roles: roles} do
      scratch_dir = create_temp_git_repo()
      demo_dir = Path.join(scratch_dir, "demo")
      File.mkdir_p!(demo_dir)

      File.write!(
        Path.join(demo_dir, "manifest.json"),
        Jason.encode!(%{"version" => 1, "outcome" => "recorded"})
      )

      {:ok, task} =
        Pipeline.update_task(system_scope(), task.id, %{
          stage: :demo,
          stage_state: :running,
          worktree_path: "/tmp/rail-removed-worktree"
        })

      {:ok, role_run} =
        Runs.create_role_run(%{
          task_id: task.id,
          role_id: roles[:engineer].id,
          conversation_id: "sess_fixture",
          status: :running,
          started_at: DateTime.utc_now()
        })

      {:ok, _persisted} = Pipeline.update_task(system_scope(), task.id, %{scratch_path: scratch_dir})

      run =
        %Run{}
        |> Run.changeset(%{
          role_run_id: role_run.id,
          task_id: role_run.task_id,
          kind: :stage,
          stream_path: "/tmp/settle_demo/#{role_run.id}.ndjson",
          node: to_string(Node.self()),
          status: :running,
          started_at: DateTime.utc_now()
        })
        |> Repo.insert!()

      {:ok, _settled_task, _settled_role_run} = Pipeline.settle_run(run, %{exit_code: 0})

      assert {:ok, %Task{stage_state: :failed, error: err}, %RoleRun{status: :finished}} =
               Pipeline.settle_demo_run(run)

      assert err =~ "segments"
    end

    test "fails when capture_demo fails during demo settlement", %{task: task, roles: roles} do
      {:ok, _workspace} =
        Projects.upsert_linear_workspace(system_scope(), %{
          name: "Settle Run Workspace 14612",
          external_id: "lin_ws_settle_run_14612",
          token: "lin_api_token_settle_run_14612",
          webhook_secret: "whsec_settle_run_14612"
        })

      scratch_dir = create_temp_git_repo()
      demo_dir = Path.join(scratch_dir, "demo")
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

      LinearMock.mock_file_upload_success(put_status: 500)

      {:ok, task} =
        Pipeline.update_task(system_scope(), task.id, %{
          stage: :demo,
          stage_state: :running,
          worktree_path: "/tmp/rail-removed-worktree"
        })

      {:ok, role_run} =
        Runs.create_role_run(%{
          task_id: task.id,
          role_id: roles[:engineer].id,
          conversation_id: "sess_fixture",
          status: :running,
          started_at: DateTime.utc_now()
        })

      {:ok, _persisted} = Pipeline.update_task(system_scope(), task.id, %{scratch_path: scratch_dir})

      run =
        %Run{}
        |> Run.changeset(%{
          role_run_id: role_run.id,
          task_id: role_run.task_id,
          kind: :stage,
          stream_path: "/tmp/settle_demo/#{role_run.id}.ndjson",
          node: to_string(Node.self()),
          status: :running,
          started_at: DateTime.utc_now()
        })
        |> Repo.insert!()

      {:ok, _settled_task, _settled_role_run} = Pipeline.settle_run(run, %{exit_code: 0})

      assert {:ok, %Task{stage_state: :failed, error: err}, %RoleRun{status: :finished}} =
               Pipeline.settle_demo_run(run)

      assert byte_size(err) > 0
    end

    test "resolves criteria from the issue description and handles nonexistent worktree path", %{
      task: task,
      issue: issue,
      roles: roles
    } do
      {:ok, _workspace} =
        Projects.upsert_linear_workspace(system_scope(), %{
          name: "Settle Run Workspace 14613",
          external_id: "lin_ws_settle_run_14613",
          token: "lin_api_token_settle_run_14613",
          webhook_secret: "whsec_settle_run_14613"
        })

      scratch_dir = Path.join("/tmp", "rail_demo_wt_#{System.unique_integer([:positive])}")
      demo_dir = Path.join(scratch_dir, "demo")
      File.mkdir_p!(demo_dir)
      on_exit(fn -> File.rm_rf(scratch_dir) end)

      File.write!(Path.join(demo_dir, "frame-1.png"), "fake demo frame content 1")

      File.write!(
        Path.join(demo_dir, "manifest.json"),
        Jason.encode!(%{
          "version" => 1,
          "outcome" => "recorded",
          "note" => nil,
          "segments" => [
            %{
              "criterionIndex" => 1,
              "criterion" => "First criterion",
              "outcome" => "recorded",
              "frames" => [%{"path" => "frame-1.png", "holdMs" => 1000, "caption" => "Step 1"}]
            }
          ]
        })
      )

      Repo.update_all(from(i in Issue, where: i.id == ^issue.id),
        set: [description: "Feature details\n\n## Acceptance criteria\n- First criterion"]
      )

      {:ok, task} =
        Pipeline.update_task(system_scope(), task.id, %{
          issue_id: issue.id,
          stage: :demo,
          stage_state: :running,
          worktree_path: "/tmp/nonexistent_wt_#{System.unique_integer([:positive])}"
        })

      {:ok, role_run} =
        Runs.create_role_run(%{
          task_id: task.id,
          role_id: roles[:engineer].id,
          conversation_id: "sess_fixture",
          status: :running,
          started_at: DateTime.utc_now(),
          stage_fingerprint_head_sha: "head_fallback",
          stage_fingerprint_dirty_digest: "digest_fallback"
        })

      mock_demo_uploads(1)

      LinearMock.mock_create_comment_success(%{"id" => "lin_cmt_demo_criteria", "body" => "Demo"})

      {:ok, _persisted} = Pipeline.update_task(system_scope(), task.id, %{scratch_path: scratch_dir})

      run =
        %Run{}
        |> Run.changeset(%{
          role_run_id: role_run.id,
          task_id: role_run.task_id,
          kind: :stage,
          stream_path: "/tmp/settle_demo/#{role_run.id}.ndjson",
          node: to_string(Node.self()),
          status: :running,
          started_at: DateTime.utc_now()
        })
        |> Repo.insert!()

      {:ok, _settled_task, _settled_role_run} = Pipeline.settle_run(run, %{exit_code: 0})

      assert {:ok, %Task{stage: :ready_to_merge, stage_state: :awaiting_approval}, %RoleRun{status: :finished}} =
               Pipeline.settle_demo_run(run)
    end

    test "handles non-git worktree directory gracefully during demo settlement", %{task: task, roles: roles} do
      {:ok, _workspace} =
        Projects.upsert_linear_workspace(system_scope(), %{
          name: "Settle Run Workspace 14614",
          external_id: "lin_ws_settle_run_14614",
          token: "lin_api_token_settle_run_14614",
          webhook_secret: "whsec_settle_run_14614"
        })

      scratch_dir = Path.join("/tmp", "rail_non_git_#{System.unique_integer([:positive])}")
      File.mkdir_p!(scratch_dir)
      on_exit(fn -> File.rm_rf(scratch_dir) end)
      demo_dir = Path.join(scratch_dir, "demo")
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

      {:ok, task} =
        Pipeline.update_task(system_scope(), task.id, %{
          stage: :demo,
          stage_state: :running,
          worktree_path: scratch_dir,
          scratch_path: scratch_dir
        })

      {:ok, role_run} =
        Runs.create_role_run(%{
          task_id: task.id,
          role_id: roles[:engineer].id,
          conversation_id: "sess_fixture",
          status: :running,
          started_at: DateTime.utc_now(),
          stage_fingerprint_head_sha: "some_sha",
          stage_fingerprint_dirty_digest: "some_digest"
        })

      mock_demo_uploads(1)

      run =
        %Run{}
        |> Run.changeset(%{
          role_run_id: role_run.id,
          task_id: role_run.task_id,
          kind: :stage,
          stream_path: "/tmp/settle_demo/#{role_run.id}.ndjson",
          node: to_string(Node.self()),
          status: :running,
          started_at: DateTime.utc_now()
        })
        |> Repo.insert!()

      {:ok, _settled_task, _settled_role_run} = Pipeline.settle_run(run, %{exit_code: 0})

      assert {:ok, %Task{stage: :ready_to_merge, stage_state: :awaiting_approval}, %RoleRun{status: :finished}} =
               Pipeline.settle_demo_run(run)
    end

    test "resolves demo target from scratch_dir when task has no worktree_path", %{task: task, roles: roles} do
      {:ok, _workspace} =
        Projects.upsert_linear_workspace(system_scope(), %{
          name: "Settle Run Workspace 14615",
          external_id: "lin_ws_settle_run_14615",
          token: "lin_api_token_settle_run_14615",
          webhook_secret: "whsec_settle_run_14615"
        })

      {:ok, task} =
        Pipeline.update_task(system_scope(), task.id, %{
          stage: :demo,
          stage_state: :running,
          worktree_path: "/tmp/rail-removed-worktree"
        })

      {:ok, role_run} =
        Runs.create_role_run(%{
          task_id: task.id,
          role_id: roles[:engineer].id,
          conversation_id: "sess_fixture",
          status: :running,
          started_at: DateTime.utc_now()
        })

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

      run =
        %Run{}
        |> Run.changeset(%{
          role_run_id: role_run.id,
          task_id: role_run.task_id,
          kind: :stage,
          stream_path: "/tmp/settle_demo/#{role_run.id}.ndjson",
          node: to_string(Node.self()),
          status: :running,
          started_at: DateTime.utc_now()
        })
        |> Repo.insert!()

      {:ok, _settled_task, _settled_role_run} = Pipeline.settle_run(run, %{exit_code: 0})

      assert {:ok, %Task{stage: :ready_to_merge, stage_state: :awaiting_approval}, %RoleRun{status: :finished}} =
               Pipeline.settle_demo_run(run)
    end

    test "supports explicit criteria in opts when settling demo", %{task: task, roles: roles} do
      {:ok, _workspace} =
        Projects.upsert_linear_workspace(system_scope(), %{
          name: "Settle Run Workspace 14616",
          external_id: "lin_ws_settle_run_14616",
          token: "lin_api_token_settle_run_14616",
          webhook_secret: "whsec_settle_run_14616"
        })

      worktree_dir = Path.join("/tmp", "rail_demo_wt_#{System.unique_integer([:positive])}")
      demo_dir = Path.join(worktree_dir, "demo")
      File.mkdir_p!(demo_dir)
      on_exit(fn -> File.rm_rf(worktree_dir) end)

      File.write!(Path.join(demo_dir, "frame-1.png"), "fake demo frame content 1")

      File.write!(
        Path.join(demo_dir, "manifest.json"),
        Jason.encode!(%{
          "version" => 1,
          "outcome" => "recorded",
          "note" => nil,
          "segments" => [
            %{
              "criterionIndex" => 1,
              "criterion" => "Explicit criterion",
              "outcome" => "recorded",
              "frames" => [%{"path" => "frame-1.png", "holdMs" => 1000, "caption" => "Step 1"}]
            }
          ]
        })
      )

      {:ok, task} =
        Pipeline.update_task(system_scope(), task.id, %{
          stage: :demo,
          stage_state: :running,
          worktree_path: worktree_dir,
          scratch_path: worktree_dir
        })

      {:ok, role_run} =
        Runs.create_role_run(%{
          task_id: task.id,
          role_id: roles[:engineer].id,
          conversation_id: "sess_fixture",
          status: :running,
          started_at: DateTime.utc_now()
        })

      mock_demo_uploads(1)

      run =
        %Run{}
        |> Run.changeset(%{
          role_run_id: role_run.id,
          task_id: role_run.task_id,
          kind: :stage,
          stream_path: "/tmp/settle_demo/#{role_run.id}.ndjson",
          node: to_string(Node.self()),
          status: :running,
          started_at: DateTime.utc_now()
        })
        |> Repo.insert!()

      {:ok, _settled_task, _settled_role_run} = Pipeline.settle_run(run, %{exit_code: 0})

      assert {:ok, %Task{stage: :ready_to_merge}, %RoleRun{status: :finished}} =
               Pipeline.settle_demo_run(run, %{}, criteria: ["Explicit criterion"])
    end
  end
end
