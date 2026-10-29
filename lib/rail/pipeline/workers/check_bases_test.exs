defmodule Rail.Pipeline.Workers.CheckBasesTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Git
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Pipeline.Workers.CheckBases

  test "checks the tasks under review or ready to merge, and none before or after", %{project: project} do
    tasks =
      Map.new([review: "CBS-1", finalize: "CBS-2", engineer: "CBS-3", merged: "CBS-4"], fn {stage, identifier} ->
        task = learnings_task(project, identifier, stage)
        # Git is stubbed, so each worktree is only looked for: a plain directory stands in for it.
        worktree_path = Path.join(System.tmp_dir!(), "rail_cbs_wt_#{System.unique_integer([:positive])}")
        File.mkdir_p!(worktree_path)
        on_exit(fn -> File.rm_rf(worktree_path) end)
        {:ok, task} = Pipeline.update_task(task, %{worktree_path: worktree_path})
        on_exit(fn -> File.rm_rf(task.scratch_path) end)
        {stage, task}
      end)

    stub(Git, :base_status, fn _path, _base -> %{behind: true, conflicts: []} end)

    assert :ok = perform_job(CheckBases, %{})

    assert %Task{base_behind: true} = Repo.reload!(tasks.review)
    assert %Task{base_behind: true} = Repo.reload!(tasks.finalize)
    assert %Task{base_behind: false, base_checked_at: nil} = Repo.reload!(tasks.engineer)
    assert %Task{base_behind: false, base_checked_at: nil} = Repo.reload!(tasks.merged)
  end
end
