defmodule Rail.Pipeline.Actions.DeclineDemoTest do
  use Rail.DataCase, async: true

  import RailTest.PipelineHelpers

  alias Rail.Artifacts
  alias Rail.Artifacts.Schemas.Demo
  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Scope
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    scope = system_scope()

    {:ok, workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Decline Demo Workspace",
        external_id: "lin_ws_decline_demo",
        token: "lin_api_token_decline_demo",
        webhook_secret: "whsec_decline_demo"
      })

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Decline Demo Project 8601",
        github_repo: "org/decline-demo-8601",
        github_installation_id: 8601,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_decline_demo_8601",
        linear_team_key: "P8601",
        clone_path: "/tmp/repos/decline-demo-8601",
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
            stage: stage,
            name: "#{stage} role",
            model: "claude-3-7-sonnet",
            system_prompt: "You are the #{stage} agent."
          })

        {stage, role}
      end)

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_decline_demo_1",
      "identifier" => "DCD-1",
      "title" => "Decline Demo Issue"
    })

    {:ok, issue} = Issues.capture_issue(scope, project, "Decline Demo Issue")

    LinearMock.mock_update_issue_success(%{"id" => "lin_decline_demo_1"})

    {:ok, task} = Pipeline.bring_local(scope, issue)

    %{project: project, issue: issue, task: task, roles: roles}
  end

  test "declines demo with default note, creates demo record, and advances to ready_to_merge", %{task: task} do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :demo,
        stage_state: :queued,
        error: "Previous error"
      })

    assert {:ok,
            %Task{
              id: task_id,
              stage: :ready_to_merge,
              stage_state: :awaiting_approval,
              error: nil,
              retry_after: nil
            }} = Pipeline.decline_demo(task)

    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :demo_declined}}

    assert %Demo{
             task_id: ^task_id,
             version: 1,
             outcome: "declined",
             note: "Declined by human",
             stale: false,
             segments: []
           } = Repo.one(from d in Demo, where: d.task_id == ^task_id)
  end

  test "declines demo with custom note and increments version on subsequent demo", %{task: task} do
    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :demo,
        stage_state: :queued
      })

    demo_manifest_8651 =
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

    expect(File, :exists?, fn _path -> true end)

    expect(File, :read, fn _path -> {:ok, demo_manifest_8651} end)

    expect(File, :stat, fn _path -> {:ok, %File.Stat{type: :regular, size: 128}} end)

    expect(File, :read, fn _path -> {:ok, "PNG_FRAME"} end)

    mock_demo_uploads(1)

    LinearMock.mock_create_comment_success(%{
      "id" => "cmt_demo_8651",
      "body" => "Demo",
      "createdAt" => "2026-09-05T12:00:00.000Z"
    })

    {:ok, _demo} = Artifacts.capture_demo(system_scope(), task, "/tmp/rail_scratch/demo_8651")

    assert {:ok, %Task{stage: :ready_to_merge, stage_state: :awaiting_approval}} =
             Pipeline.decline_demo(Scope.for_system(), task.id, "Non-UI refactor, CLI verified")

    latest_demo =
      Repo.one(
        from d in Demo,
          where: d.task_id == ^task.id,
          order_by: [desc: d.version],
          limit: 1
      )

    assert %Demo{
             version: 2,
             outcome: "declined",
             note: "Non-UI refactor, CLI verified"
           } = latest_demo
  end

  test "declines demo and records fingerprint when worktree is on disk", %{task: task} do
    worktree = create_temp_git_repo()

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :demo,
        stage_state: :queued,
        worktree_path: worktree
      })

    assert {:ok, %Task{stage: :ready_to_merge, stage_state: :awaiting_approval}} =
             Pipeline.decline_demo(task, "No demo needed")

    assert %Demo{
             head_sha: head_sha,
             dirty_digest: dirty_digest,
             outcome: "declined"
           } = Repo.one(from d in Demo, where: d.task_id == ^task.id)

    assert is_binary(head_sha) and head_sha != ""
    assert is_binary(dirty_digest) and dirty_digest != ""
  end

  test "enforces authorization", %{task: task} do
    assert {:error, :not_authorized} =
             Pipeline.decline_demo(%Scope{system: false, user: nil}, task, "Note")

    assert {:ok, %Task{}} =
             Pipeline.decline_demo(Scope.user_scope(), task, "Note")
  end

  test "returns not found for unknown task" do
    assert {:error, :not_found} =
             Pipeline.decline_demo("tsk_nonexistent_9999", "Note")

    assert {:error, :not_found} =
             Pipeline.decline_demo(:bad_id, "Note")
  end

  test "declines demo when worktree path is a non-git directory", %{task: task} do
    scratch_worktree = create_temp_git_repo()

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :demo,
        stage_state: :queued,
        worktree_path: scratch_worktree
      })

    assert {:ok, %Task{stage: :ready_to_merge}} = Pipeline.decline_demo(task, "Non-git worktree")
  end
end
