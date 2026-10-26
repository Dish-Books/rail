defmodule Rail.Pipeline.Workers.StartReviewChecksTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Pipeline.Workers.StartReviewChecks
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess

  setup %{project: project} do
    issue =
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: project.id,
        external_id: "lin_start_review_checks",
        identifier: "SRC-1",
        title: "Hosts on the Sandboxes page",
        state: :todo
      })
      |> Repo.insert!()
      |> Repo.preload(:project)

    {:ok, task} = Pipeline.create_task(issue, :review)
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: create_temp_git_repo(), submitted_at: DateTime.utc_now()})
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    test_pid = self()

    # A spawn that writes its row, as the real one does before anything can fail.
    spawned = fn run, _argv ->
      process =
        Repo.insert!(%OsProcess{
          run_id: run.id,
          task_id: run.task_id,
          stream_path: "/tmp/src.ndjson",
          status: :running,
          started_at: DateTime.utc_now()
        })

      send(test_pid, {:started, Repo.preload(run, :role, force: true).role.stage})
      send(test_pid, {:slot, Repo.preload(run, :task).task.worktree_slot})
      {:ok, %{process | run: run}}
    end

    %{project: project, task: task, spawned: spawned}
  end

  test "starts QA and the code reviewer on a task handed over at Review", %{task: task, spawned: spawned} do
    stub(Tools, :start_os_process, spawned)

    assert :ok = perform_job(StartReviewChecks, %{task_id: task.id})

    assert_received {:started, :qa}
    assert_received {:started, :review}
    refute_received {:started, _other}

    # Both share the one slot the worktree was prepared with.
    %Task{worktree_slot: slot} = Repo.reload!(task)
    assert_received {:slot, ^slot}
    assert_received {:slot, ^slot}
  end

  test "an attempt that died after both checks spawned starts nothing", %{task: task, spawned: spawned} do
    expect(Tools, :start_os_process, 2, spawned)
    handed_at = DateTime.shift(DateTime.utc_now(), second: -1)

    assert :ok = perform_job(StartReviewChecks, %{task_id: task.id}, inserted_at: handed_at)
    assert :ok = perform_job(StartReviewChecks, %{task_id: task.id}, inserted_at: handed_at, attempt: 2)

    assert [%OsProcess{}, %OsProcess{}] = Tools.list_os_processes(task_id: task.id)
  end

  test "an attempt that died after QA spawned starts only the code reviewer, leaving QA's run and report alone", %{
    project: project,
    task: task,
    spawned: spawned
  } do
    handed_at = DateTime.shift(DateTime.utc_now(), second: -1)
    {:ok, qa} = Roles.get_role(project_id: project.id, stage: :qa)

    {:ok, %Run{id: qa_run_id}} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: qa.id,
        status: :finished,
        stage_outcome: :done,
        started_at: DateTime.utc_now()
      })

    Repo.insert!(%OsProcess{
      run_id: qa_run_id,
      task_id: task.id,
      stream_path: "/tmp/src_qa.ndjson",
      status: :finished,
      started_at: DateTime.utc_now()
    })

    report = Path.join([task.scratch_path, "reports", "qa.md"])
    File.mkdir_p!(Path.dirname(report))
    File.write!(report, "Checked every screen.")

    expect(Tools, :start_os_process, spawned)

    assert :ok = perform_job(StartReviewChecks, %{task_id: task.id}, inserted_at: handed_at, attempt: 2)

    assert_received {:started, :review}
    refute_received {:started, _other}
    assert %Run{status: :finished, stage_outcome: :done} = Repo.get!(Run, qa_run_id)
    assert File.read!(report) == "Checked every screen."
  end

  test "with a setup script, the setup runs once on the first check's run and nothing else starts", %{
    project: project,
    task: task
  } do
    project |> Ecto.Changeset.change(worktree_setup_script: "bin/setup") |> Repo.update!()
    handed_at = DateTime.shift(DateTime.utc_now(), second: -1)
    test_pid = self()

    expect(Tools, :start_command_process, fn %Run{} = run, :setup, "./bin/setup", _opts ->
      process =
        Repo.insert!(%OsProcess{
          run_id: run.id,
          task_id: run.task_id,
          kind: :setup,
          stream_path: "/tmp/src_setup.log",
          status: :running,
          started_at: DateTime.utc_now()
        })

      send(test_pid, {:setup, Repo.preload(run, :task, force: true).task.worktree_slot})
      {:ok, %{process | run: run}}
    end)

    reject(&Tools.start_os_process/2)

    assert :ok = perform_job(StartReviewChecks, %{task_id: task.id}, inserted_at: handed_at)
    # The setup will start the rest, so a retry leaves them to it.
    assert :ok = perform_job(StartReviewChecks, %{task_id: task.id}, inserted_at: handed_at, attempt: 2)

    assert_received {:setup, slot}
    assert %Task{worktree_slot: ^slot} = Repo.reload!(task)
    assert is_integer(slot)
    assert [%OsProcess{kind: :setup}] = Tools.list_os_processes(task_id: task.id)
  end

  test "a worktree that cannot be made fails each check on why, starting nothing", %{project: project, task: task} do
    # The clone has main checked out, so git will not check it out again in a worktree.
    clone = create_temp_git_repo()
    project |> Ecto.Changeset.change(clone_path: clone, worktree_setup_script: "bin/setup") |> Repo.update!()
    {:ok, task} = Pipeline.update_task(task, %{worktree_name: "main", worktree_path: Path.join(clone, ".worktrees/main")})

    reject(&Tools.start_command_process/4)
    reject(&Tools.start_os_process/2)

    assert :ok = perform_job(StartReviewChecks, %{task_id: task.id})

    assert [
             %Run{status: :failed, error: "Could not prepare the worktree" <> _qa},
             %Run{status: :failed, error: "Could not prepare the worktree" <> _review}
           ] = Repo.preload(task, :runs, force: true).runs
  end

  test "a task that has left Review, or was cleaned up, is left alone", %{task: task} do
    reject(&Tools.start_os_process/2)

    {:ok, task} = Pipeline.update_task(task, %{stage: :plan})
    assert :ok = perform_job(StartReviewChecks, %{task_id: task.id})

    {:ok, task} = Pipeline.update_task(task, %{stage: :review, cleaned_up_at: DateTime.utc_now()})
    assert :ok = perform_job(StartReviewChecks, %{task_id: task.id})

    assert [] = Repo.preload(task, :runs, force: true).runs
  end

  test "a task that is gone needs nothing" do
    assert :ok = perform_job(StartReviewChecks, %{task_id: "tsk_gone"})
  end
end
