defmodule Rail.Pipeline.Workers.StartEngineerTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Pipeline.Workers.StartEngineer
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess

  setup %{project: project} do
    stub(Rail.Git, :get_or_create_worktree, fn _project, task -> {:ok, task.worktree_path} end)

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
