defmodule Rail.Pipeline.Actions.PickDesignDirectionTest do
  use Rail.DataCase, async: true

  import RailTest.PipelineHelpers

  alias Rail.Artifacts
  alias Rail.Artifacts.Schemas.Design
  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Runs
  alias Rail.Runs.Schemas.RoleRun
  alias Rail.Scope
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    scope = system_scope()

    {:ok, workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Pick Design Workspace",
        external_id: "lin_ws_pick_design",
        token: "lin_api_token_pick_design",
        webhook_secret: "whsec_pick_design"
      })

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Pick Design Project 9301",
        github_repo: "org/pick-design-9301",
        github_installation_id: 9301,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_pick_design_9301",
        linear_team_key: "P9301",
        clone_path: "/tmp/repos/pick-design-9301",
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
      "id" => "lin_pick_design_1",
      "identifier" => "PDD-1",
      "title" => "Pick Design Issue"
    })

    {:ok, issue} = Issues.capture_issue(scope, project, "Pick Design Issue")

    LinearMock.mock_update_issue_success(%{"id" => "lin_pick_design_1"})

    {:ok, task} = Pipeline.bring_local(scope, issue)

    %{project: project, issue: issue, task: task, roles: roles}
  end

  test "picks design direction, updates picked_key, and queues designer run with pick brief", %{task: task, roles: roles} do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")

    {:ok, designer_role} =
      Roles.update_role(system_scope(), roles[:design], %{
        name: "Designer"
      })

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :design,
        stage_state: :awaiting_approval
      })

    design_manifest_9801 =
      Jason.encode!(%{
        "canvasUrl" => "https://canvas.example.com/design-9801",
        "version" => 1,
        "pickedKey" => nil,
        "directions" => [
          %{"key" => "dir-1", "title" => "Minimal Light", "notes" => "Clean", "stillPath" => "dir-1.png"},
          %{"key" => "dir-2", "title" => "Bold Dark", "notes" => "High contrast", "stillPath" => "dir-2.png"}
        ]
      })

    expect(File, :exists?, 3, fn _path -> true end)

    expect(File, :read, fn _path -> {:ok, design_manifest_9801} end)

    expect(File, :stat, 2, fn _path -> {:ok, %File.Stat{type: :regular, size: 128}} end)

    expect(File, :read, 2, fn _path -> {:ok, "PNG_STILL"} end)

    mock_design_uploads(2)

    {:ok, _design} =
      Artifacts.capture_design(system_scope(), task, "/tmp/rail_scratch/design_9801", url_probe: fn _url -> true end)

    {:ok, _role_run} =
      Runs.create_role_run(%{
        task_id: task.id,
        role_id: designer_role.id,
        status: :finished,
        started_at: DateTime.utc_now()
      })

    assert {:ok, %Task{id: task_id, stage: :design, stage_state: :queued, error: nil}} =
             Pipeline.pick_design_direction(task, "dir-2")

    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :changes_requested}}

    updated_design = Repo.one(from d in Design, where: d.task_id == ^task.id, order_by: [desc: d.version], limit: 1)
    assert updated_design.picked_key == "dir-2"

    run = Repo.one(from r in RoleRun, where: r.task_id == ^task.id and r.role_id == ^designer_role.id)
    assert run.pending_answer =~ ~s(The human picked direction "Bold Dark")
    assert run.pending_answer =~ ~s(key: "dir-2")
  end

  test "returns error when task stage is not design", %{task: task} do
    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :product,
        stage_state: :awaiting_approval
      })

    assert {:error, {:invalid_stage, :product}} =
             Pipeline.pick_design_direction(task, "dir-1")
  end

  test "returns not_found when task does not exist" do
    assert {:error, :not_found} =
             Pipeline.pick_design_direction("tsk_000000000000000000000000", "dir-1")
  end

  test "returns not_authorized when scope lacks permission", %{task: task} do
    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :design,
        stage_state: :awaiting_approval
      })

    unauth_scope = %Scope{user: nil, system: false}

    assert {:error, :not_authorized} =
             Pipeline.pick_design_direction(unauth_scope, task.id, "dir-1")
  end

  test "returns design_not_found when task has no design record", %{task: task} do
    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :design,
        stage_state: :awaiting_approval
      })

    assert {:error, :design_not_found} =
             Pipeline.pick_design_direction(task, "dir-1")
  end

  test "returns direction_not_found when specified key does not exist", %{task: task} do
    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :design,
        stage_state: :awaiting_approval
      })

    design_manifest_9802 =
      Jason.encode!(%{
        "canvasUrl" => "https://canvas.example.com/design-9802",
        "version" => 1,
        "pickedKey" => nil,
        "directions" => [
          %{"key" => "dir-1", "title" => "Direction 1", "notes" => "Notes", "stillPath" => "dir-1.png"}
        ]
      })

    expect(File, :exists?, 2, fn _path -> true end)

    expect(File, :read, fn _path -> {:ok, design_manifest_9802} end)

    expect(File, :stat, fn _path -> {:ok, %File.Stat{type: :regular, size: 128}} end)

    expect(File, :read, fn _path -> {:ok, "PNG_STILL"} end)

    mock_design_uploads(1)

    {:ok, _design} =
      Artifacts.capture_design(system_scope(), task, "/tmp/rail_scratch/design_9802", url_probe: fn _url -> true end)

    assert {:error, {:direction_not_found, "nonexistent-key"}} =
             Pipeline.pick_design_direction(task, "nonexistent-key")
  end

  test "supports all arities and user scope invocation", %{task: task, roles: roles} do
    {:ok, _designer_role} =
      Roles.update_role(system_scope(), roles[:design], %{
        name: "Designer"
      })

    user_scope = %Scope{user: %{id: "usr_1"}, system: false}

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :design,
        stage_state: :awaiting_approval
      })

    design_manifest_9803 =
      Jason.encode!(%{
        "canvasUrl" => "https://canvas.example.com/design-9803",
        "version" => 1,
        "pickedKey" => nil,
        "directions" => [
          %{"key" => "dir-1", "title" => "Direction 1", "notes" => "Notes", "stillPath" => "dir-1.png"}
        ]
      })

    expect(File, :exists?, 2, fn _path -> true end)

    expect(File, :read, fn _path -> {:ok, design_manifest_9803} end)

    expect(File, :stat, fn _path -> {:ok, %File.Stat{type: :regular, size: 128}} end)

    expect(File, :read, fn _path -> {:ok, "PNG_STILL"} end)

    mock_design_uploads(1)

    {:ok, _design} =
      Artifacts.capture_design(system_scope(), task, "/tmp/rail_scratch/design_9803", url_probe: fn _url -> true end)

    assert {:ok, %Task{stage: :design, stage_state: :queued}} =
             Pipeline.pick_design_direction(user_scope, task.id, "dir-1", [])

    assert {:ok, %Task{stage: :design, stage_state: :queued}} =
             Pipeline.pick_design_direction(user_scope, task, "dir-1")

    assert {:ok, %Task{stage: :design, stage_state: :queued}} =
             Pipeline.pick_design_direction(task.id, "dir-1", [])

    assert {:error, :not_found} = Pipeline.pick_design_direction(12_345, "dir-1")
  end

  test "returns direction_not_found when design has nil directions", %{task: task} do
    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :design,
        stage_state: :awaiting_approval
      })

    design_manifest_9804 =
      Jason.encode!(%{
        "canvasUrl" => "https://canvas.example.com/design-9804",
        "version" => 1,
        "pickedKey" => nil,
        "directions" => [
          %{"key" => "dir-1", "title" => "Direction 1", "notes" => "Notes", "stillPath" => "dir-1.png"}
        ]
      })

    expect(File, :exists?, 2, fn _path -> true end)

    expect(File, :read, fn _path -> {:ok, design_manifest_9804} end)

    expect(File, :stat, fn _path -> {:ok, %File.Stat{type: :regular, size: 128}} end)

    expect(File, :read, fn _path -> {:ok, "PNG_STILL"} end)

    mock_design_uploads(1)

    {:ok, design} =
      Artifacts.capture_design(system_scope(), task, "/tmp/rail_scratch/design_9804", url_probe: fn _url -> true end)

    Repo.update_all(from(d in Design, where: d.id == ^design.id), set: [directions: nil])

    assert {:error, {:direction_not_found, "dir-1"}} =
             Pipeline.pick_design_direction(task, "dir-1")
  end
end
