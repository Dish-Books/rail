defmodule Rail.Pipeline.Workers.StartCuratorTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Git
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Workers.StartCurator
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess

  setup %{project: project} do
    stub(Git, :get_or_create_worktree, fn _project, task -> {:ok, task.worktree_path} end)
    stub(Git, :branch_fingerprint, fn _path -> nil end)
    task = learnings_task(project, "SCW-1", :finalize)
    File.mkdir_p!(Path.join(task.scratch_path, "worktree"))
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    {:ok, task} =
      Pipeline.update_task(task, %{
        worktree_path: Path.join(task.scratch_path, "worktree"),
        pr_number: 42,
        marked_ready_at: DateTime.utc_now()
      })

    {:ok, curator} = Roles.get_role(project_id: project.id, stage: :curator)
    %{task: task, curator: curator}
  end

  test "starts the curator on the task it was queued for", %{task: task, curator: %{id: curator_id}} do
    expect(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)

    assert :ok = perform_job(StartCurator, %{task_id: task.id})
    assert [%Run{role_id: ^curator_id, status: :running}] = Pipeline.list_runs(task_id: task.id)
  end

  test "waits and tries again while the curator is mid-turn", %{task: task, curator: curator} do
    {:ok, _running} =
      Pipeline.create_run(%{task_id: task.id, role_id: curator.id, status: :running, started_at: DateTime.utc_now()})

    reject(Tools, :start_os_process, 2)
    assert {:snooze, 30} = perform_job(StartCurator, %{task_id: task.id})
  end

  test "a task deleted while the job waited starts nothing", %{task: task} do
    reject(Tools, :start_os_process, 2)
    assert :ok = perform_job(StartCurator, %{task_id: "tsk_gone"})
    assert [] = Pipeline.list_runs(task_id: task.id)
  end
end
