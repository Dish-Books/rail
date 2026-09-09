defmodule Rail.Pipeline.Actions.PickDesignDirectionTest do
  use Rail.DataCase, async: false

  alias Rail.Artifacts.Schemas.Design
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Runs.Schemas.RoleRun
  alias Rail.Scope

  test "picks design direction, updates picked_key, and queues designer run with pick brief" do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")
    project = create_test_project()
    designer_role = create_test_role(%{project_id: project.id, stage: :design, name: "Designer"})

    task =
      create_test_task(%{
        project_id: project.id,
        stage: :design,
        stage_state: :awaiting_approval
      })

    create_test_design(%{
      task_id: task.id,
      version: 1,
      picked_key: nil,
      directions: [
        %{key: "dir-1", title: "Minimal Clean", notes: "Clean white aesthetic", still_url: "https://linear.app/s1.png"},
        %{key: "dir-2", title: "Bold Dark", notes: "Dark theme with neon", still_url: "https://linear.app/s2.png"}
      ]
    })

    create_test_role_run(%{
      task_id: task.id,
      role_id: designer_role.id,
      status: :finished
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

  test "returns error when task stage is not design" do
    project = create_test_project()
    task = create_test_task(%{project_id: project.id, stage: :product, stage_state: :awaiting_approval})

    assert {:error, {:invalid_stage, :product}} =
             Pipeline.pick_design_direction(task, "dir-1")
  end

  test "returns not_found when task does not exist" do
    assert {:error, :not_found} =
             Pipeline.pick_design_direction("tsk_000000000000000000000000", "dir-1")
  end

  test "returns not_authorized when scope lacks permission" do
    task = create_test_task(%{stage: :design, stage_state: :awaiting_approval})
    unauth_scope = %Scope{user: nil, system: false}

    assert {:error, :not_authorized} =
             Pipeline.pick_design_direction(unauth_scope, task.id, "dir-1")
  end

  test "returns design_not_found when task has no design record" do
    project = create_test_project()
    task = create_test_task(%{project_id: project.id, stage: :design, stage_state: :awaiting_approval})

    assert {:error, :design_not_found} =
             Pipeline.pick_design_direction(task, "dir-1")
  end

  test "returns direction_not_found when specified key does not exist" do
    project = create_test_project()
    task = create_test_task(%{project_id: project.id, stage: :design, stage_state: :awaiting_approval})

    create_test_design(%{
      task_id: task.id,
      version: 1,
      directions: [%{key: "dir-1", title: "Minimal", notes: "Notes", still_url: "https://linear.app/s1.png"}]
    })

    assert {:error, {:direction_not_found, "nonexistent-key"}} =
             Pipeline.pick_design_direction(task, "nonexistent-key")
  end

  test "supports all arities and user scope invocation" do
    project = create_test_project()
    _designer_role = create_test_role(%{project_id: project.id, stage: :design, name: "Designer"})
    user_scope = %Scope{user: %{id: "usr_1"}, system: false}

    task = create_test_task(%{project_id: project.id, stage: :design, stage_state: :awaiting_approval})

    create_test_design(%{
      task_id: task.id,
      directions: [%{key: "dir-1", title: "D1", notes: "N1", still_url: "https://linear.app/s1.png"}]
    })

    assert {:ok, %Task{stage: :design, stage_state: :queued}} =
             Pipeline.pick_design_direction(user_scope, task.id, "dir-1", [])

    assert {:ok, %Task{stage: :design, stage_state: :queued}} =
             Pipeline.pick_design_direction(user_scope, task, "dir-1")

    assert {:ok, %Task{stage: :design, stage_state: :queued}} =
             Pipeline.pick_design_direction(task.id, "dir-1", [])

    assert {:error, :not_found} = Pipeline.pick_design_direction(12_345, "dir-1")
  end

  test "returns direction_not_found when design has nil directions" do
    project = create_test_project()
    task = create_test_task(%{project_id: project.id, stage: :design, stage_state: :awaiting_approval})

    design = create_test_design(%{task_id: task.id})
    Repo.update_all(from(d in Design, where: d.id == ^design.id), set: [directions: nil])

    assert {:error, {:direction_not_found, "dir-1"}} =
             Pipeline.pick_design_direction(task, "dir-1")
  end
end
