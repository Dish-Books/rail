defmodule Rail.Pipeline.Actions.RecheckDesignTest do
  use Rail.DataCase, async: false

  alias Rail.Artifacts.Schemas.Design
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Runs.Schemas.RunEvent
  alias Rail.Scope

  test "lands a design the gate turned down once the canvas is published" do
    project = create_test_project()
    create_test_linear_workspace(%{project_id: project.id})
    designer_role = create_test_role(%{project_id: project.id, stage: :design, name: "Designer"})
    worktree_dir = create_test_design_dir(canvas_url: "https://claude.ai/design/valid-canvas")

    task =
      create_test_task(%{
        project_id: project.id,
        stage: :design,
        stage_state: :failed,
        error: "Canvas URL could not be opened or returned 404/410",
        worktree_path: worktree_dir
      })

    role_run =
      create_test_role_run(%{
        task_id: task.id,
        role_id: designer_role.id,
        status: :finished
      })

    mock_design_uploads(2)

    assert {:ok, %Task{id: task_id, stage: :design, stage_state: :awaiting_approval, error: nil}} =
             Pipeline.recheck_design(task, url_probe: fn _uri -> true end)

    reloaded_task = Repo.get!(Task, task_id)
    assert reloaded_task.stage_state == :awaiting_approval
    assert is_nil(reloaded_task.error)

    design = Repo.one(from d in Design, where: d.task_id == ^task_id, order_by: [desc: d.version], limit: 1)
    assert design.canvas_url == "https://claude.ai/design/valid-canvas"

    events = Repo.all(from e in RunEvent, where: e.role_run_id == ^role_run.id, order_by: [asc: e.seq])
    assert Enum.any?(events, fn e -> e.line =~ "[axis] Design re-checked: manifest v1 accepted." end)
  end

  test "reads the same manifest twice without turning it down" do
    project = create_test_project()
    create_test_linear_workspace(%{project_id: project.id})
    _designer_role = create_test_role(%{project_id: project.id, stage: :design, name: "Designer"})

    worktree_dir =
      create_test_design_dir(canvas_url: "https://claude.ai/design/canvas-same", version: 2, picked_key: "dir-1")

    task =
      create_test_task(%{
        project_id: project.id,
        stage: :design,
        stage_state: :failed,
        error: "Initial gate failure",
        worktree_path: worktree_dir
      })

    create_test_design(%{
      task_id: task.id,
      version: 2,
      picked_key: "dir-1",
      directions: [%{key: "dir-1", title: "D1", notes: "N1", still_url: "https://linear.app/s1.png"}]
    })

    mock_design_uploads(4)

    assert {:ok, %Task{stage_state: :awaiting_approval, error: nil}} =
             Pipeline.recheck_design(task, url_probe: fn _uri -> true end)

    assert {:ok, %Task{stage_state: :awaiting_approval, error: nil}} =
             Pipeline.recheck_design(task, url_probe: fn _uri -> true end)
  end

  test "says why a design still does not hold up, and leaves the stage failed" do
    project = create_test_project()
    designer_role = create_test_role(%{project_id: project.id, stage: :design, name: "Designer"})
    worktree_dir = create_test_design_dir(canvas_url: "invalid-not-https-url")

    task =
      create_test_task(%{
        project_id: project.id,
        stage: :design,
        stage_state: :failed,
        error: "Initial failure",
        worktree_path: worktree_dir
      })

    role_run =
      create_test_role_run(%{
        task_id: task.id,
        role_id: designer_role.id,
        status: :finished
      })

    assert {:error, reason} = Pipeline.recheck_design(task)
    assert reason =~ "absolute https URL"

    reloaded_task = Repo.get!(Task, task.id)
    assert reloaded_task.stage_state == :failed
    assert reloaded_task.error =~ "absolute https URL"

    events = Repo.all(from e in RunEvent, where: e.role_run_id == ^role_run.id, order_by: [asc: e.seq])

    assert Enum.any?(events, fn e ->
             e.line =~ "[axis] Design re-check turned it down:" and e.line =~ "absolute https URL"
           end)
  end

  test "returns error when designer is actively running" do
    project = create_test_project()
    task = create_test_task(%{project_id: project.id, stage: :design, stage_state: :running})

    assert {:error, "The Designer is still running; wait for it to finish."} =
             Pipeline.recheck_design(task)
  end

  test "noops and returns ok when task stage is not design" do
    project = create_test_project()
    task = create_test_task(%{project_id: project.id, stage: :engineer, stage_state: :awaiting_approval})

    assert {:ok, %Task{stage: :engineer}} = Pipeline.recheck_design(task)
  end

  test "fails when manifest is missing pickedKey after a pick" do
    project = create_test_project()
    worktree_dir = create_test_design_dir(canvas_url: "https://claude.ai/canvas/pick-check", picked_key: nil)

    task =
      create_test_task(%{
        project_id: project.id,
        stage: :design,
        stage_state: :failed,
        worktree_path: worktree_dir
      })

    create_test_design(%{
      task_id: task.id,
      version: 1,
      picked_key: "dir-1"
    })

    assert {:error, reason} = Pipeline.recheck_design(task, url_probe: fn _uri -> true end)
    assert reason =~ "Design manifest is missing pickedKey (expected \"dir-1\")."
  end

  test "fails when manifest pickedKey does not match chosen direction" do
    project = create_test_project()
    worktree_dir = create_test_design_dir(canvas_url: "https://claude.ai/canvas/pick-check", picked_key: "dir-2")

    task =
      create_test_task(%{
        project_id: project.id,
        stage: :design,
        stage_state: :failed,
        worktree_path: worktree_dir
      })

    create_test_design(%{
      task_id: task.id,
      version: 1,
      picked_key: "dir-1"
    })

    assert {:error, reason} = Pipeline.recheck_design(task, url_probe: fn _uri -> true end)
    assert reason =~ "does not match chosen direction (dir-1)"
  end

  test "fails when manifest does not contain chosen direction" do
    project = create_test_project()

    directions = [
      %{
        "key" => "dir-other",
        "title" => "Other",
        "notes" => "Other notes",
        "stillPath" => ".axis/design/dir-1.png"
      }
    ]

    worktree_dir =
      create_test_design_dir(
        canvas_url: "https://claude.ai/canvas/pick-check",
        picked_key: "dir-1",
        directions: directions
      )

    task =
      create_test_task(%{
        project_id: project.id,
        stage: :design,
        stage_state: :failed,
        worktree_path: worktree_dir
      })

    create_test_design(%{
      task_id: task.id,
      version: 1,
      picked_key: "dir-1"
    })

    assert {:error, reason} = Pipeline.recheck_design(task, url_probe: fn _uri -> true end)
    assert reason =~ "Manifest missing picked direction: dir-1"
  end

  test "computes design_manifest_stamp and handles missing files" do
    worktree_dir = create_test_design_dir()
    stamp = Pipeline.design_manifest_stamp(worktree_dir)
    assert stamp =~ ~r/^\d+:\d+$/

    assert is_nil(Pipeline.design_manifest_stamp("/tmp/nonexistent_design_dir_#{System.unique_integer([:positive])}"))
    assert is_nil(Pipeline.design_manifest_stamp(nil))
  end

  test "authorizes scope with user and handles invalid task argument" do
    project = create_test_project()
    user_scope = %Scope{user: %{id: "usr_recheck"}, system: false}
    unauth_scope = %Scope{user: nil, system: false}

    task = create_test_task(%{project_id: project.id, stage: :engineer})

    assert {:ok, %Task{stage: :engineer}} = Pipeline.recheck_design(user_scope, task.id)
    assert {:error, :not_authorized} = Pipeline.recheck_design(unauth_scope, task.id)
    assert {:error, :not_found} = Pipeline.recheck_design(user_scope, "tsk_000000000000000000000000")
    assert {:error, :not_found} = Pipeline.recheck_design(user_scope, 12_345)
  end

  test "computes design_manifest_stamp from task struct and root manifest.json" do
    worktree_dir = create_test_design_dir()
    task = create_test_task(%{worktree_path: worktree_dir})

    assert Pipeline.design_manifest_stamp(task) =~ ~r/^\d+:\d+$/

    root_dir = create_temp_scratch_dir()
    File.write!(Path.join(root_dir, "manifest.json"), "{}")
    assert Pipeline.design_manifest_stamp(root_dir) =~ ~r/^\d+:\d+$/
  end

  test "supports scratch_dir, scratch_path, worktree_path opts and nil task worktree_path" do
    project = create_test_project()
    create_test_linear_workspace(%{project_id: project.id})
    worktree_dir = create_test_design_dir()

    task_no_wt = create_test_task(%{project_id: project.id, stage: :design, worktree_path: nil})

    mock_design_uploads(2)

    assert {:ok, %Task{stage_state: :awaiting_approval}} =
             Pipeline.recheck_design(task_no_wt, scratch_dir: worktree_dir, url_probe: fn _uri -> true end)

    mock_design_uploads(2)

    assert {:ok, %Task{stage_state: :awaiting_approval}} =
             Pipeline.recheck_design(task_no_wt, scratch_path: worktree_dir, url_probe: fn _uri -> true end)

    mock_design_uploads(2)

    assert {:ok, %Task{stage_state: :awaiting_approval}} =
             Pipeline.recheck_design(task_no_wt, worktree_path: worktree_dir, url_probe: fn _uri -> true end)

    # When no opt and no worktree_path, falls back to default_scratch_path
    assert {:error, err} = Pipeline.recheck_design(task_no_wt, url_probe: fn _uri -> true end)
    assert err =~ "No design manifest found"
  end
end
