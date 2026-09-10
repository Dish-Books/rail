defmodule Rail.Pipeline.Actions.GetTaskTest do
  use Rail.DataCase, async: true

  import RailTest.PipelineHelpers

  alias Rail.Artifacts
  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Scope
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    scope = system_scope()

    {:ok, workspace} =
      Projects.upsert_linear_workspace(scope, %{
        name: "Get Task Workspace",
        external_id: "lin_ws_get_task",
        token: "lin_api_token_get_task",
        webhook_secret: "whsec_get_task"
      })

    {:ok, project} =
      Projects.create_project(scope, %{
        name: "Get Task Project",
        github_repo: "org/get-task",
        github_installation_id: 6401,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_get_task",
        linear_team_key: "GTK",
        clone_path: "/tmp/repos/get-task",
        linear_state_ids: %{"triage" => "st_triage", "in_progress" => "st_in_progress"}
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_get_task_1",
      "identifier" => "GTK-1",
      "title" => "Get Task Issue"
    })

    {:ok, issue} = Issues.capture_issue(scope, project, "Get Task Issue")

    LinearMock.mock_update_issue_success(%{"id" => "lin_get_task_1"})

    {:ok, task} = Pipeline.create_task(issue)

    %{project: project, issue: issue, task: task}
  end

  test "returns task for authenticated user scope", %{task: %Task{id: task_id} = task} do
    scope = Scope.for_user(%{admin: false})

    assert {:ok, %Task{id: ^task_id}} = Pipeline.get_task(scope, task.id)
  end

  test "returns task for system scope", %{task: %Task{id: task_id} = task} do
    scope = Scope.for_system()

    assert {:ok, %Task{id: ^task_id}} = Pipeline.get_task(scope, task.id)
  end

  test "returns not found error when task does not exist" do
    scope = Scope.for_system()
    assert {:error, :not_found} = Pipeline.get_task(scope, "tsk_000000000000000000000000")
  end

  test "returns not authorized error for nil or invalid scope", %{task: task} do
    assert {:error, :not_authorized} = Pipeline.get_task(nil, task.id)
    assert {:error, :not_authorized} = Pipeline.get_task(%Scope{user: nil, system: false}, task.id)
  end

  test "get_task! returns task for system scope", %{task: %Task{id: task_id} = task} do
    scope = Scope.for_system()

    assert %Task{id: ^task_id} = Pipeline.get_task!(scope, task.id)
  end

  test "get_task! returns task for user scope", %{task: %Task{id: task_id} = task} do
    scope = Scope.for_user(%{admin: false})

    assert %Task{id: ^task_id} = Pipeline.get_task!(scope, task.id)
  end

  test "get_task! raises Ecto.NoResultsError when task does not exist" do
    scope = Scope.for_system()

    assert_raise Ecto.NoResultsError, fn ->
      Pipeline.get_task!(scope, "tsk_000000000000000000000000")
    end
  end

  test "get_task! raises Ecto.NoResultsError when scope is unauthorized", %{task: task} do
    assert_raise Ecto.NoResultsError, fn ->
      Pipeline.get_task!(nil, task.id)
    end
  end

  test "loads and attaches latest demo and design to task", %{task: %Task{id: task_id} = task} do
    scope = Scope.for_system()

    recorded_manifest =
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
    expect(File, :read, fn _path -> {:ok, recorded_manifest} end)
    expect(File, :stat, fn _path -> {:ok, %File.Stat{type: :regular, size: 128}} end)
    expect(File, :read, fn _path -> {:ok, "PNG_FRAME"} end)
    mock_demo_uploads(1)

    LinearMock.mock_create_comment_success(%{
      "id" => "cmt_demo_1",
      "body" => "Demo recorded",
      "createdAt" => "2026-09-05T12:00:00.000Z"
    })

    {:ok, _demo1} = Artifacts.capture_demo(scope, task, "/tmp/rail_scratch/demo_1")

    declined_manifest =
      Jason.encode!(%{"version" => 2, "outcome" => "declined", "note" => "Not needed", "segments" => []})

    expect(File, :exists?, fn _path -> true end)
    expect(File, :read, fn _path -> {:ok, declined_manifest} end)

    LinearMock.mock_create_comment_success(%{
      "id" => "cmt_demo_2",
      "body" => "Demo declined",
      "createdAt" => "2026-09-05T12:00:00.000Z"
    })

    {:ok, %{id: demo2_id}} = Artifacts.capture_demo(scope, task, "/tmp/rail_scratch/demo_2")

    design_manifest = fn version, picked ->
      Jason.encode!(%{
        "canvasUrl" => "https://canvas.example.com/design-#{version}",
        "version" => version,
        "pickedKey" => picked,
        "directions" => [
          %{"key" => "dir-1", "title" => "Direction 1", "notes" => "Notes", "stillPath" => "dir-1.png"}
        ]
      })
    end

    expect(File, :exists?, 2, fn _path -> true end)
    expect(File, :read, fn _path -> {:ok, design_manifest.(1, nil)} end)
    expect(File, :stat, fn _path -> {:ok, %File.Stat{type: :regular, size: 128}} end)
    expect(File, :read, fn _path -> {:ok, "PNG_STILL"} end)
    mock_design_uploads(1)

    {:ok, _design1} =
      Artifacts.capture_design(scope, task, "/tmp/rail_scratch/design_1", url_probe: fn _url -> true end)

    expect(File, :exists?, 2, fn _path -> true end)
    expect(File, :read, fn _path -> {:ok, design_manifest.(2, "dir-2")} end)
    expect(File, :stat, fn _path -> {:ok, %File.Stat{type: :regular, size: 128}} end)
    expect(File, :read, fn _path -> {:ok, "PNG_STILL"} end)
    mock_design_uploads(1)

    {:ok, %{id: design2_id}} =
      Artifacts.capture_design(scope, task, "/tmp/rail_scratch/design_2", url_probe: fn _url -> true end)

    assert {:ok,
            %Task{
              id: ^task_id,
              demo: %{id: ^demo2_id, version: 2},
              design: %{id: ^design2_id, version: 2}
            }} = Pipeline.get_task(scope, task.id)

    assert %Task{
             id: ^task_id,
             demo: %{id: ^demo2_id, version: 2},
             design: %{id: ^design2_id, version: 2}
           } = Pipeline.get_task!(scope, task.id)
  end

  test "returns nil for demo and design when task has no artifacts", %{task: %Task{id: task_id} = task} do
    scope = Scope.for_system()

    assert {:ok, %Task{id: ^task_id, demo: nil, design: nil}} = Pipeline.get_task(scope, task.id)
    assert %Task{id: ^task_id, demo: nil, design: nil} = Pipeline.get_task!(scope, task.id)
  end
end
