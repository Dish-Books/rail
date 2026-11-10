defmodule Rail.Pipeline.Workers.RecheckBaseTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  import ExUnit.CaptureLog

  alias Rail.Git
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Pipeline.Workers.RecheckBase

  setup %{project: project} do
    task = learnings_task(project, "RCB-1", :finalize)
    # Git is stubbed, so the worktree is only looked for: a plain directory stands in for it.
    worktree_path = Path.join(System.tmp_dir!(), "rail_rcb_wt_#{System.unique_integer([:positive])}")
    File.mkdir_p!(worktree_path)
    on_exit(fn -> File.rm_rf(worktree_path) end)
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: worktree_path})
    on_exit(fn -> File.rm_rf(task.scratch_path) end)
    %{task: task}
  end

  test "fetches the default branch before checking, so a move GitHub saw first shows as Update", %{
    task: %Task{id: task_id, worktree_path: worktree_path} = task
  } do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline")
    test_pid = self()

    expect(Git, :fetch_default_branch, fn _project, ^worktree_path ->
      send(test_pid, :fetched)
      :ok
    end)

    expect(Git, :base_status, fn ^worktree_path, "main" ->
      assert_received :fetched
      %{behind: true, conflicts: ["lib/a.ex"]}
    end)

    assert :ok = perform_job(RecheckBase, %{task_id: task_id})
    assert %Task{base_behind: true, base_conflicts: ["lib/a.ex"]} = Repo.reload!(task)
    assert_received {:pipeline_changed, ^task_id}
  end

  test "a fetch that fails still checks against the copy fetched last", %{task: task} do
    stub(Git, :fetch_default_branch, fn _project, _path -> {:error, "fatal: unable to access"} end)
    stub(Git, :base_status, fn _path, _base -> %{behind: true, conflicts: []} end)

    assert capture_log(fn -> assert :ok = perform_job(RecheckBase, %{task_id: task.id}) end) =~
             "Could not fetch"

    assert %Task{base_behind: true} = Repo.reload!(task)
  end

  test "a task cleaned up or without its worktree is left alone", %{task: task} do
    reject(Git, :fetch_default_branch, 2)
    reject(Git, :base_status, 2)

    {:ok, cleaned} = Pipeline.update_task(task, %{cleaned_up_at: DateTime.utc_now()})
    assert :ok = perform_job(RecheckBase, %{task_id: cleaned.id})

    {:ok, gone} = Pipeline.update_task(cleaned, %{cleaned_up_at: nil})
    File.rm_rf!(gone.worktree_path)
    assert :ok = perform_job(RecheckBase, %{task_id: gone.id})

    {:ok, _deleted} = Repo.delete(gone)
    assert :ok = perform_job(RecheckBase, %{task_id: gone.id})
  end
end
