defmodule Rail.Pipeline.Actions.StartCuratorTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Learnings
  alias Rail.Learnings.Schemas.LearningProposal
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess

  setup %{project: project} do
    task = learnings_task(project, "SCU-1", :finalize)
    # Git is only ever asked through Rail.Git, so the worktree is a plain directory on a clean branch.
    worktree = Path.join(task.scratch_path, "worktree")
    File.mkdir_p!(worktree)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)
    stub(Git, :get_or_create_worktree, fn _project, task -> {:ok, task.worktree_path} end)
    stub(Git, :branch_fingerprint, fn _path -> %{head_sha: String.duplicate("a", 40), dirty_digest: "clean"} end)

    {:ok, task} =
      Pipeline.update_task(task, %{worktree_path: worktree, pr_number: 41, marked_ready_at: DateTime.utc_now()})

    {:ok, curator} = Roles.get_role(project_id: project.id, stage: :curator)
    %{task: task, curator: curator, dir: Path.join(task.scratch_path, "learnings")}
  end

  test "the first pass writes the task's files and starts the curator on a new conversation", %{
    task: %Task{id: task_id} = task,
    curator: %{id: curator_id},
    dir: dir
  } do
    expect(Tools, :start_os_process, fn %Run{} = spawned, argv ->
      refute "--resume" in argv
      assert Enum.any?(argv, &(&1 =~ dir))
      assert File.exists?(Path.join(dir, "ticket.md"))
      assert File.read!(Path.join(dir, "proposals.md")) =~ "# Your proposals on this task so far"
      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %Run{task_id: ^task_id, role_id: ^curator_id, status: :running}} = Pipeline.start_curator(task)
  end

  test "a second pass while the curator is mid-turn starts no second process", %{task: task} do
    expect(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)
    {:ok, %Run{id: run_id}} = Pipeline.start_curator(task)

    reject(Tools, :start_os_process, 2)
    assert {:error, :curator_running} = Pipeline.start_curator(task)
    assert [%Run{id: ^run_id}] = Pipeline.list_runs(task_id: task.id)
  end

  test "after a fix round the pass resumes the same conversation and lists every earlier proposal with its decision",
       %{task: task, curator: curator, dir: dir} do
    {:ok, %Run{id: run_id}} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: curator.id,
        status: :finished,
        stage_outcome: :done,
        conversation_id: "sess_curator",
        started_at: DateTime.utc_now()
      })

    {:ok, %LearningProposal{id: rejected_id} = rejected} =
      Learnings.save_task_proposal(task, %{action: "add", rule: "Retry flaky tests", kind: "qa", title: "Retry"})

    {:ok, _rejected} = Learnings.reject_learning_proposal(system_scope(), rejected)

    {:ok, %LearningProposal{id: pending_id}} =
      Learnings.save_task_proposal(task, %{action: "add", rule: "Broadcast after commit", kind: "convention"})

    expect(Tools, :start_os_process, fn %Run{} = spawned, argv ->
      assert "sess_curator" in argv
      proposals = File.read!(Path.join(dir, "proposals.md"))
      assert proposals =~ "## #{rejected_id} · Add · rejected"
      assert proposals =~ "## #{pending_id} · Add · pending\n\n\n\nBroadcast after commit"
      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %Run{id: ^run_id, conversation_id: "sess_curator", status: :running}} = Pipeline.start_curator(task)
  end

  test "a task not marked ready, a merged one, and one in a project with no curator start nothing", %{task: task} do
    reject(Tools, :start_os_process, 2)

    {:ok, unmarked} = Pipeline.update_task(task, %{marked_ready_at: nil})
    assert :ok = Pipeline.start_curator(unmarked)

    {:ok, merged} = Pipeline.update_task(task, %{marked_ready_at: DateTime.utc_now(), merged_at: DateTime.utc_now()})
    assert :ok = Pipeline.start_curator(merged)

    {:ok, unconfigured} = Pipeline.update_task(merged, %{merged_at: nil})
    stub(Roles, :get_role, fn [project_id: _project_id, stage: :curator] -> {:error, :role_not_found} end)
    assert :ok = Pipeline.start_curator(unconfigured)

    assert [] = Pipeline.list_runs(task_id: task.id)
  end

  test "a task merged while its files were written starts nothing", %{task: task} do
    reject(Tools, :start_os_process, 2)

    # The files are written before the lock is taken, so a merge can land between the two.
    expect(Learnings, :write_task_files, fn written, dir ->
      {:ok, _merged} = Pipeline.update_task(written, %{merged_at: DateTime.utc_now()})
      Mimic.call_original(Learnings, :write_task_files, [written, dir])
    end)

    assert :ok = Pipeline.start_curator(task)
    assert [] = Pipeline.list_runs(task_id: task.id)
  end
end
