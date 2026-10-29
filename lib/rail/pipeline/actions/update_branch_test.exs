defmodule Rail.Pipeline.Actions.UpdateBranchTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Git
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Round
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Pipeline.Workers.StartEngineer
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Users

  setup %{project: project} do
    task = learnings_task(project, "UPB-1", :review)
    # Git is stubbed, so the worktree is only looked for: a plain directory stands in for it.
    worktree_path = Path.join(System.tmp_dir!(), "rail_upb_wt_#{System.unique_integer([:positive])}")
    File.mkdir_p!(worktree_path)
    on_exit(fn -> File.rm_rf(worktree_path) end)

    {:ok, task} = Pipeline.update_task(task, %{worktree_path: worktree_path, marked_ready_at: DateTime.utc_now()})

    on_exit(fn -> File.rm_rf(task.scratch_path) end)
    Repo.insert!(%Round{task_id: task.id, number: 1, plan: "Filter by vendor.", approved_at: DateTime.utc_now()})
    stub(Git, :read_default_branch_file, fn _project, path -> {:error, "fatal: path '#{path}' does not exist"} end)
    stub(Git, :base_status, fn _path, "main" -> %{behind: true, conflicts: ["lib/a.ex", "lib/b.ex"]} end)
    stub(Git, :branch_fingerprint, fn _worktree_path -> %{head_sha: String.duplicate("a", 40), dirty_digest: "clean"} end)

    {:ok, %{id: ada_id} = ada} =
      Users.register_oauth_user(%{github_id: "gh_upb_ada", login: "ada-update-branch", email: "ada-upb@example.com"})

    %{task: task, ada: user_scope(user: %{ada | project_ids: [project.id]}), ada_id: ada_id}
  end

  test "starts a round on the branch's head, approved by whoever clicked, that merges the default branch in and names the conflicts",
       %{
         task: %Task{id: task_id, worktree_path: worktree_path} = task,
         ada: ada,
         ada_id: ada_id
       } do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline")
    # The start is the job's, committed with the round, so it survives the page that clicked.
    reject(Tools, :start_os_process, 2)
    head = String.duplicate("b", 40)
    expect(Git, :branch_fingerprint, fn ^worktree_path -> %{head_sha: head, dirty_digest: "clean"} end)

    assert {:ok, %Round{number: 2, approved_by_id: ^ada_id, approved_at: %DateTime{}, plan: plan, base_head: ^head}} =
             Pipeline.update_branch(ada, task)

    assert plan =~
             "Bring the branch up to date with `origin/main` by merging it in. It conflicts in `lib/a.ex`, `lib/b.ex`."

    assert %Round{number: 2} = Pipeline.read_plan(task)
    # The branch moves, so a task marked ready is not ready any more.
    assert %Task{stage: :engineer, marked_ready_at: nil, base_behind: true} = Repo.reload!(task)
    assert_enqueued(worker: StartEngineer, args: %{task_id: task_id})
    assert_received {:pipeline_changed, ^task_id}
  end

  test "a branch that merges cleanly is still brought up to date, with nothing named in conflict", %{
    task: task,
    ada: ada
  } do
    stub(Git, :base_status, fn _path, _base -> %{behind: true, conflicts: []} end)

    assert {:ok, %Round{plan: plan}} = Pipeline.update_branch(ada, task)
    assert plan =~ "It merges cleanly as Rail last checked"
  end

  test "is refused for a branch already up to date, while anything works, or outside Review and Finalize", %{
    project: project,
    task: task,
    ada: ada
  } do
    assert {:error, :not_found} = Pipeline.update_branch(user_scope(), task)

    stub(Git, :base_status, fn _path, _base -> %{behind: false, conflicts: []} end)
    assert {:error, :up_to_date} = Pipeline.update_branch(ada, task)

    {:ok, qa} = Roles.get_role(project_id: project.id, stage: :qa)

    {:ok, _working} =
      Pipeline.create_run(%{task_id: task.id, role_id: qa.id, status: :running, started_at: DateTime.utc_now()})

    assert {:error, :stage_running} = Pipeline.update_branch(ada, task)

    {:ok, _merged} = Pipeline.update_task(task, %{stage: :merged})
    assert {:error, {:invalid_stage, :merged}} = Pipeline.update_branch(ada, task)
    assert [%Round{number: 1}] = Pipeline.list_rounds(task)
  end
end
