defmodule Rail.Pipeline.Actions.RetryRunTest do
  use Rail.DataCase, async: true

  import Rail.Pipeline.Utils.WithTaskLock

  alias Rail.Git
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess

  setup %{project: project} do
    task = learnings_task(project, "RTR-1", :review)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    # Git is only ever asked through Rail.Git, so the worktree is a plain directory, on the commit whose sha is all a's
    # with nothing changed against main.
    worktree = Path.join(task.scratch_path, "worktree")
    File.mkdir_p!(worktree)
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: worktree})
    stub(Git, :get_or_create_worktree, fn _project, _task -> {:ok, worktree} end)

    stub(Git, :branch_fingerprint, fn ^worktree ->
      %{head_sha: String.duplicate("a", 40), dirty_digest: String.duplicate("0", 64)}
    end)

    stub(Git, :load_diff, fn _scope, %{worktree_path: ^worktree}, :branch -> {:ok, []} end)

    run = fn stage, attrs ->
      {:ok, role} = Roles.get_role(project_id: project.id, stage: stage)

      {:ok, run} =
        Pipeline.create_run(
          Map.merge(%{task_id: task.id, role_id: role.id, status: :finished, started_at: DateTime.utc_now()}, attrs)
        )

      run
    end

    %{task: task, run: run}
  end

  # A check is only worth what it read of the round, so it starts over rather than resuming.
  test "a failed check starts again on a clean conversation", %{run: run} do
    %Run{id: qa_id} = qa = run.(:qa, %{error: "Chrome went away", conversation_id: "sess_qa"})

    expect(Tools, :start_os_process, fn %Run{id: ^qa_id, conversation_id: nil} = spawned, argv ->
      refute "--resume" in argv
      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %Run{id: ^qa_id}} = Pipeline.retry_run(system_scope(), qa)
  end

  # A round that changed nothing a person sees skipped QA, and a person may still want it walked.
  test "QA skipped on its round starts on a clean conversation", %{run: run} do
    %Run{id: qa_id} = qa = run.(:qa, %{stage_outcome: :skipped, conversation_id: "sess_qa"})

    expect(Tools, :start_os_process, fn %Run{id: ^qa_id, conversation_id: nil} = spawned, _argv ->
      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %Run{id: ^qa_id, stage_outcome: :in_progress}} = Pipeline.retry_run(system_scope(), qa)
  end

  test "the review agent picks its conversation up again", %{run: run} do
    %Run{id: lead_id} =
      lead = run.(:review_lead, %{error: "The review agent did not save its review.", conversation_id: "sess_lead"})

    expect(Tools, :start_os_process, fn %Run{id: ^lead_id, conversation_id: "sess_lead"} = spawned, _argv ->
      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %Run{id: ^lead_id}} = Pipeline.retry_run(system_scope(), lead)
  end

  test "a run deleted while the retry waited on the task's lock is not retried", %{task: task, run: run} do
    %Run{id: lead_id} = lead = run.(:review_lead, %{error: "It broke.", conversation_id: "sess_lead"})
    reject(Tools, :start_os_process, 2)

    pending =
      with_task_lock(task.id, fn ->
        pending = Elixir.Task.async(fn -> Pipeline.retry_run(system_scope(), lead) end)
        refute Elixir.Task.yield(pending, 100)
        Repo.delete_all(from(r in Run, where: r.id == ^lead_id))
        pending
      end)

    assert {:error, :not_retryable} = Elixir.Task.await(pending)
  end

  test "a run that no longer exists is not retried", %{run: run} do
    %Run{id: lead_id} = lead = run.(:review_lead, %{error: "It broke."})
    Repo.delete_all(from(r in Run, where: r.id == ^lead_id))

    assert {:error, :not_retryable} = Pipeline.retry_run(system_scope(), lead)
  end

  test "is refused for a run that has not failed, one of another step, while anything works, or outside the project",
       %{task: task, run: run} do
    reject(Tools, :start_os_process, 2)

    assert {:error, :not_retryable} = Pipeline.retry_run(system_scope(), run.(:review, %{}))
    assert {:error, :not_retryable} = Pipeline.retry_run(system_scope(), run.(:engineer, %{error: "It broke."}))
    assert {:error, :not_found} = Pipeline.retry_run(user_scope(), run.(:qa, %{error: "It broke."}))

    {:ok, _engineer} = Pipeline.update_task(task, %{stage: :engineer})
    _working = run.(:plan, %{status: :running})
    assert {:error, :stage_running} = Pipeline.retry_run(system_scope(), run.(:demo, %{error: "It broke."}))
  end
end
