defmodule Rail.Pipeline.Workers.StartEngineerTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  import Rail.Pipeline.Utils.WithTaskLock

  alias Rail.Git
  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Pipeline.Workers.StartEngineer
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess

  setup %{project: project} do
    stub(Git, :get_or_create_worktree, fn _project, task -> {:ok, task.worktree_path} end)

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_start_engineer_1", "identifier" => "STE-1", "title" => "Start Engineer"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{title: "Start Engineer"})
    {:ok, task} = Pipeline.create_task(issue, :engineer)
    {:ok, engineer} = Roles.get_role(project_id: project.id, stage: :engineer)

    # A spawn that writes its row, as the real one does before anything can fail.
    spawned = fn run, _argv ->
      process =
        Repo.insert!(%OsProcess{
          run_id: run.id,
          task_id: run.task_id,
          stream_path: "/tmp/ste.ndjson",
          status: :running,
          started_at: DateTime.utc_now()
        })

      {:ok, %{process | run: run}}
    end

    %{task: task, engineer: engineer, spawned: spawned}
  end

  test "starts the engineer on a task approved into Engineer", %{task: task, engineer: engineer, spawned: spawned} do
    expect(Tools, :start_os_process, spawned)

    assert :ok = perform_job(StartEngineer, %{task_id: task.id})

    assert %Run{status: :running, stage_outcome: :in_progress} =
             Repo.get_by(Run, task_id: task.id, role_id: engineer.id)
  end

  test "a task deleted while the job waited on its lock starts nothing", %{task: %Task{id: task_id} = task} do
    reject(Tools, :start_os_process, 2)
    reject(Git, :get_or_create_worktree, 2)

    pending =
      with_task_lock(task_id, fn ->
        pending = Elixir.Task.async(fn -> perform_job(StartEngineer, %{task_id: task_id}) end)
        refute Elixir.Task.yield(pending, 100)
        Repo.delete!(task)
        pending
      end)

    assert :ok = Elixir.Task.await(pending)
    assert Repo.all(from(r in Run, where: r.task_id == ^task_id)) == []
  end

  test "an attempt that died before its spawn is started again on the retry", %{
    task: task,
    engineer: engineer,
    spawned: spawned
  } do
    {:ok, _stranded} =
      Pipeline.create_run(%{task_id: task.id, role_id: engineer.id, status: :running, started_at: DateTime.utc_now()})

    expect(Tools, :start_os_process, spawned)

    assert :ok = perform_job(StartEngineer, %{task_id: task.id})
    assert [%OsProcess{}] = Tools.list_os_processes(task_id: task.id)
  end

  test "an attempt that died after its spawn is not spawned twice", %{task: task, spawned: spawned} do
    expect(Tools, :start_os_process, spawned)
    approved_at = DateTime.shift(DateTime.utc_now(), second: -1)

    assert :ok = perform_job(StartEngineer, %{task_id: task.id}, inserted_at: approved_at)
    assert :ok = perform_job(StartEngineer, %{task_id: task.id}, inserted_at: approved_at, attempt: 2)

    assert [%OsProcess{}] = Tools.list_os_processes(task_id: task.id)
  end

  test "a task approved again after a return to Plan starts again, whatever its earlier round spawned", %{
    task: task,
    spawned: spawned
  } do
    expect(Tools, :start_os_process, 2, spawned)

    assert :ok = perform_job(StartEngineer, %{task_id: task.id})

    assert :ok =
             perform_job(StartEngineer, %{task_id: task.id}, inserted_at: DateTime.shift(DateTime.utc_now(), second: 1))

    assert [%OsProcess{}, %OsProcess{}] = Tools.list_os_processes(task_id: task.id)
  end

  test "a task that has left Engineer is left alone", %{task: task} do
    reject(&Tools.start_os_process/2)
    {:ok, %Task{}} = Pipeline.update_task(task, %{stage: :plan})

    assert :ok = perform_job(StartEngineer, %{task_id: task.id})
    assert [] = Repo.preload(task, :runs, force: true).runs
  end

  test "an approved custom stage's job starts Plan on a task it moved to Plan", %{task: task, spawned: spawned} do
    {:ok, %Task{}} = Pipeline.update_task(task, %{stage: :plan})
    test_pid = self()

    expect(Tools, :start_os_process, fn %Run{role: %Role{stage: :plan}} = run, argv ->
      send(test_pid, :plan_started)
      spawned.(run, argv)
    end)

    assert :ok = perform_job(StartEngineer, %{task_id: task.id, stage: "plan"})
    assert_received :plan_started
  end

  describe "an approved custom stage's job on a task it moved to Review" do
    setup %{task: task} do
      {:ok, reviewing} = Pipeline.update_task(task, %{stage: :review, worktree_path: create_temp_git_repo()})
      on_exit(fn -> File.rm_rf(reviewing.scratch_path) end)
      stub(Git, :base_status, fn _path, _base -> %{behind: true, conflicts: []} end)
      %{task: reviewing}
    end

    test "checks the base and starts QA and the code reviewer", %{task: task, spawned: spawned} do
      test_pid = self()

      stub(Tools, :start_os_process, fn run, argv ->
        send(test_pid, {:started, Repo.preload(run, :role, force: true).role.stage})
        spawned.(run, argv)
      end)

      assert :ok = perform_job(StartEngineer, %{task_id: task.id, stage: "review"})

      assert %Task{base_behind: true} = Repo.reload!(task)
      for stage <- [:qa, :review], do: assert_received({:started, ^stage})
    end

    test "starts nothing again once a check has spawned", %{task: task, spawned: spawned} do
      expect(Tools, :start_os_process, 2, spawned)
      approved_at = DateTime.shift(DateTime.utc_now(), second: -1)

      assert :ok = perform_job(StartEngineer, %{task_id: task.id, stage: "review"}, inserted_at: approved_at)

      assert :ok =
               perform_job(StartEngineer, %{task_id: task.id, stage: "review"}, inserted_at: approved_at, attempt: 2)

      assert [%OsProcess{}, %OsProcess{}] = Tools.list_os_processes(task_id: task.id)
    end
  end

  # A plan approved just before Discard must not rebuild the worktree and push the branch again.
  test "a task cleaned up after the job was queued is left alone", %{task: task} do
    reject(&Tools.start_os_process/2)
    {:ok, %Task{}} = Pipeline.update_task(task, %{cleaned_up_at: DateTime.utc_now()})

    assert :ok = perform_job(StartEngineer, %{task_id: task.id})
    assert [] = Repo.preload(task, :runs, force: true).runs
  end

  test "a task that is gone needs nothing" do
    assert :ok = perform_job(StartEngineer, %{task_id: "tsk_gone"})
  end
end
