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
    {:ok, lead} = Roles.get_role(project_id: project.id, stage: :review_lead)

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: lead.id,
        status: :finished,
        stage_outcome: :done,
        conversation_id: "sess_record_demo",
        started_at: DateTime.utc_now()
      })

    %{task: task, run: run, scope: user_scope()}
  end

  test "asks the idle Review lead, as the person who clicked, to record the demo again", %{
    task: task,
    run: %Run{id: run_id} = run,
    scope: scope
  } do
    stub(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)

    assert {:ok, :sent, %Run{id: ^run_id}} = Pipeline.record_demo(scope, task)

    assert ["[human:" <> said] = run |> Pipeline.list_run_events() |> Enum.map(& &1.line)
    assert said =~ "#{scope.user.id}] Record the demo again"
  end

  # The first click set the lead working, so a second is refused rather than queued behind it.
  test "is refused while the lead works", %{task: task, run: run, scope: scope} do
    {:ok, _working} = Pipeline.update_run(run, %{status: :running})
    reject(Tools, :start_os_process, 2)

    assert {:error, :stage_running} = Pipeline.record_demo(scope, task)
    assert [] = Pipeline.list_run_events(run)
  end

  test "is refused once the task is not at Review, or before Review has a run", %{task: task, run: run, scope: scope} do
    {:ok, merged} = Pipeline.update_task(task, %{stage: :merged})
    assert {:error, {:invalid_stage, :merged}} = Pipeline.record_demo(scope, merged)

    Repo.delete!(run)
    assert {:error, :no_stage_run} = Pipeline.record_demo(scope, task)
  end
end
