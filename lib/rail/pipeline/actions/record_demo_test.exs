defmodule Rail.Pipeline.Actions.RecordDemoTest do
  use Rail.DataCase, async: true

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess

  setup %{project: project} do
    task = learnings_task(project, "RDM-1", :review)
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: create_temp_git_repo()})
    on_exit(fn -> File.rm_rf(task.scratch_path) end)
    {:ok, demo} = Roles.get_role(project_id: project.id, stage: :demo)

    %{task: task, demo: demo, scope: user_scope(project_ids: [project.id])}
  end

  test "starts the demo recorder as a run of its own, on a clean conversation", %{
    task: task,
    demo: %{id: demo_id},
    scope: scope
  } do
    {:ok, _earlier} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: demo_id,
        status: :finished,
        conversation_id: "sess_last_take",
        started_at: DateTime.utc_now()
      })

    expect(Tools, :start_os_process, fn %Run{role_id: ^demo_id, conversation_id: nil} = run,
                                        ["-p", prompt | _rest] = argv ->
      assert prompt =~ "You record the demo of the change below"
      refute "--resume" in argv
      {:ok, %OsProcess{run: run, task: run.task}}
    end)

    assert {:ok, %Run{role_id: ^demo_id, status: :running}} = Pipeline.record_demo(scope, task)
  end

  test "is refused while anything works on the task, so two clicks record once", %{task: task, demo: demo, scope: scope} do
    {:ok, _working} =
      Pipeline.create_run(%{task_id: task.id, role_id: demo.id, status: :running, started_at: DateTime.utc_now()})

    reject(Tools, :start_os_process, 2)

    assert {:error, :stage_running} = Pipeline.record_demo(scope, task)
  end

  test "is refused for a task not at Review, a project the person cannot open, or one with no demo role", %{
    task: task,
    demo: demo,
    scope: scope
  } do
    assert {:error, :not_found} = Pipeline.record_demo(user_scope(project_ids: []), task)

    Repo.delete!(demo)
    assert {:error, :not_found} = Pipeline.record_demo(scope, task)

    {:ok, merged} = Pipeline.update_task(task, %{stage: :merged})
    assert {:error, {:invalid_stage, :merged}} = Pipeline.record_demo(scope, merged)
  end
end
