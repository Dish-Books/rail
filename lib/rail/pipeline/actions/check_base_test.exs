defmodule Rail.Pipeline.Actions.CheckBaseTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task

  setup %{project: project} do
    task = learnings_task(project, "CKB-1", :review)
    # Git is stubbed, so the worktree is only looked for: a plain directory stands in for it.
    worktree_path = Path.join(System.tmp_dir!(), "rail_ckb_wt_#{System.unique_integer([:positive])}")
    File.mkdir_p!(worktree_path)
    on_exit(fn -> File.rm_rf(worktree_path) end)
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: worktree_path})
    on_exit(fn -> File.rm_rf(task.scratch_path) end)
    %{task: task}
  end

  test "records the branch behind with what conflicts, and tells the pipeline only when that changes", %{
    task: %Task{id: task_id} = task
  } do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline")
    stub(Git, :base_status, fn _path, "main" -> %{behind: true, conflicts: ["lib/a.ex"]} end)

    assert {:ok, %Task{base_behind: true, base_conflicts: ["lib/a.ex"], base_checked_at: %DateTime{}} = checked} =
             Pipeline.check_base(task)

    assert_received {:pipeline_changed, ^task_id}

    assert {:ok, %Task{base_behind: true}} = Pipeline.check_base(checked)
    refute_received {:pipeline_changed, ^task_id}
    assert %Task{base_conflicts: ["lib/a.ex"]} = Repo.reload!(task)
  end

  test "a task with no worktree is left as it is", %{task: task} do
    reject(&Git.base_status/2)

    assert {:ok, %Task{base_checked_at: nil}} = Pipeline.check_base(%{task | worktree_path: "/nonexistent/ckb"})
  end
end
