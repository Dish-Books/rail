defmodule Rail.Pipeline.Actions.RerecordDemoTest do
  use Rail.DataCase, async: true

  import RailTest.Mocks.Linear, only: [mock_demo_uploads: 1]

  alias Rail.Artifacts
  alias Rail.Artifacts.Schemas.Demo
  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Runs
  alias Rail.Runs.Schemas.Run
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    {:ok, backend} =
      Rail.Backends.create_backend(system_scope(), %{name: :claude, executable_path: "/usr/bin/true"})

    scope = system_scope()

    {:ok, workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Rerecord Demo Workspace",
        external_id: "lin_ws_rerecord_demo",
        token: "lin_api_token_rerecord_demo",
        webhook_secret: "whsec_rerecord_demo"
      })

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Rerecord Demo Project 9401",
        github_repo: "org/rerecord-demo-9401",
        github_installation_id: 9401,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_rerecord_demo_9401",
        linear_team_key: "P9401",
        default_branch: "main",
        clone_path: "/tmp/repos/rerecord-demo-9401",
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
      "id" => "lin_rerecord_demo_1",
      "identifier" => "RRD-1",
      "title" => "Rerecord Demo Issue"
    })

    {:ok, issue} = Issues.create_issue(project, %{description: "Rerecord Demo Issue"})

    {:ok, task} = Pipeline.create_task(issue, :product)

    %{project: project, issue: issue, task: task, roles: roles}
  end

  test "marks the previous demo stale and enters the demo stage again", %{task: task, roles: roles} do
    worktree = create_temp_git_repo()

    {:ok, task} = Pipeline.update_task(task, %{stage: :ready_to_merge, worktree_path: worktree})

    demo_scratch = Path.join("/tmp", "rail_demo_scratch_#{System.unique_integer([:positive])}")
    demo_dir = Path.join(demo_scratch, "demo")
    File.mkdir_p!(demo_dir)
    on_exit(fn -> File.rm_rf(demo_scratch) end)

    File.write!(Path.join(demo_dir, "frame-1.png"), "fake png content")

    File.write!(
      Path.join(demo_dir, "manifest.json"),
      Jason.encode!(%{
        "version" => 1,
        "outcome" => "recorded",
        "segments" => [
          %{
            "criterionIndex" => 1,
            "criterion" => "Feature works",
            "outcome" => "recorded",
            "frames" => [%{"path" => "frame-1.png", "holdMs" => 1000, "caption" => "Step 1"}]
          }
        ]
      })
    )

    mock_demo_uploads(1)

    LinearMock.mock_create_comment_success(%{
      "id" => "cmt_demo_9901",
      "body" => "Demo",
      "createdAt" => "2026-09-05T12:00:00.000Z"
    })

    {:ok, demo} = Artifacts.capture_demo(system_scope(), task, demo_scratch)

    {:ok, run} =
      Runs.create_run(%{
        task_id: task.id,
        role_id: roles[:demo].id,
        status: :finished,
        stage_outcome: :done,
        started_at: DateTime.utc_now()
      })

    assert {:ok, %Run{}} = Pipeline.rerecord_demo(run)

    assert %Task{stage: :demo} = Repo.reload!(task)
    assert %Demo{stale: true} = Repo.get!(Demo, demo.id)
  end

  test "records again even when there is no previous demo", %{task: task, roles: roles} do
    worktree = create_temp_git_repo()

    {:ok, task} = Pipeline.update_task(task, %{stage: :demo, worktree_path: worktree})

    {:ok, run} =
      Runs.create_run(%{
        task_id: task.id,
        role_id: roles[:demo].id,
        status: :finished,
        stage_outcome: :done,
        started_at: DateTime.utc_now()
      })

    assert {:ok, %Run{}} = Pipeline.rerecord_demo(run)
    assert %Task{stage: :demo} = Repo.reload!(task)
  end

  test "a merged task has nothing left to record from", %{task: task, roles: roles} do
    worktree = create_temp_git_repo()

    {:ok, task} = Pipeline.update_task(task, %{stage: :merged, worktree_path: worktree})

    {:ok, run} =
      Runs.create_run(%{
        task_id: task.id,
        role_id: roles[:demo].id,
        status: :finished,
        started_at: DateTime.utc_now()
      })

    assert {:error, :task_merged} = Pipeline.rerecord_demo(run)
  end

  test "a worktree that is gone records the reason on the run", %{task: task, roles: roles} do
    missing = "/tmp/nonexistent_worktree_#{System.unique_integer([:positive])}"

    {:ok, task} = Pipeline.update_task(task, %{stage: :ready_to_merge, worktree_path: missing})

    {:ok, run} =
      Runs.create_run(%{
        task_id: task.id,
        role_id: roles[:demo].id,
        status: :finished,
        started_at: DateTime.utc_now()
      })

    expected = "Worktree does not exist on disk (#{missing})."

    assert {:error, :no_worktree} = Pipeline.rerecord_demo(run)
    assert %Run{error: ^expected} = Repo.reload!(run)
  end

  test "nothing is re-recorded while anything on the task is still working", %{task: task, roles: roles} do
    worktree = create_temp_git_repo()

    {:ok, task} = Pipeline.update_task(task, %{stage: :ready_to_merge, worktree_path: worktree})

    {:ok, demo_run} =
      Runs.create_run(%{
        task_id: task.id,
        role_id: roles[:demo].id,
        status: :finished,
        stage_outcome: :done,
        started_at: DateTime.utc_now()
      })

    assert Pipeline.can_rerecord_demo?(Repo.preload(demo_run, task: :runs))

    {:ok, _engineer} =
      Runs.create_run(%{
        task_id: task.id,
        role_id: roles[:engineer].id,
        status: :running,
        started_at: DateTime.utc_now()
      })

    refute Pipeline.can_rerecord_demo?(Repo.preload(demo_run, [task: :runs], force: true))
  end

  test "a task that is merged or has lost its worktree cannot re-record", %{task: task, roles: roles} do
    {:ok, task} = Pipeline.update_task(task, %{stage: :merged, worktree_path: "/tmp/rail-removed-worktree"})

    {:ok, run} =
      Runs.create_run(%{
        task_id: task.id,
        role_id: roles[:demo].id,
        status: :finished,
        started_at: DateTime.utc_now()
      })

    refute Pipeline.can_rerecord_demo?(Repo.preload(run, task: :runs))
    refute Pipeline.can_rerecord_demo?(nil)
  end
end
