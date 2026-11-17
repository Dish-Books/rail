defmodule Rail.Pipeline.Actions.CheckLearningsTest do
  use Rail.DataCase, async: true

  alias Rail.Learnings
  alias Rail.Pipeline
  alias Rail.Pipeline.Workers.StartCurator
  alias Rail.Roles

  setup %{project: project} do
    task = learnings_task(project, "CHL-1", :finalize)
    {:ok, task} = Pipeline.update_task(task, %{pr_number: 43, marked_ready_at: DateTime.utc_now()})
    {:ok, curator} = Roles.get_role(project_id: project.id, stage: :curator)

    curator_run = fn attrs ->
      {:ok, run} =
        Pipeline.create_run(Map.merge(%{task_id: task.id, role_id: curator.id, started_at: DateTime.utc_now()}, attrs))

      run
    end

    %{task: task, curator_run: curator_run}
  end

  test "a task with no curator run and no pass queued, such as one marked before the curator, is not held", %{
    task: task
  } do
    assert :ok = Pipeline.check_learnings(task)
  end

  test "a pass queued and not started holds the task", %{task: task} do
    {:ok, _job} = %{task_id: task.id} |> StartCurator.new() |> Oban.insert()
    assert {:error, :curator_running} = Pipeline.check_learnings(task)
  end

  test "a pass queued on a project with no curator role holds nothing, since it will start nothing" do
    %{project: project} = triage_project()
    task = learnings_task(project, "CHL-2", :finalize)
    {:ok, _job} = %{task_id: task.id} |> StartCurator.new() |> Oban.insert()
    assert :ok = Pipeline.check_learnings(task)
  end

  test "a finished pass's job holds nothing", %{task: task} do
    {:ok, job} = %{task_id: task.id} |> StartCurator.new() |> Oban.insert()
    Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [state: "completed"])
    assert :ok = Pipeline.check_learnings(task)
  end

  test "a curator mid-turn, or waiting for usage, holds the task", %{task: task, curator_run: curator_run} do
    run = curator_run.(%{status: :running})
    assert {:error, :curator_running} = Pipeline.check_learnings(task)

    {:ok, _waiting} = Pipeline.update_run(run, %{status: :waiting_for_usage})
    assert {:error, :curator_running} = Pipeline.check_learnings(task)
  end

  test "a curator that failed holds the task until a turn ends without failing", %{
    task: task,
    curator_run: curator_run
  } do
    run = curator_run.(%{status: :failed, error: "Exited with code 1"})
    assert {:error, :curator_failed} = Pipeline.check_learnings(task)

    {:ok, _done} = Pipeline.update_run(run, %{status: :finished, error: nil, stage_outcome: :done})
    assert :ok = Pipeline.check_learnings(task)
  end

  test "every proposal still pending is counted, and a decided one is not", %{task: task, curator_run: curator_run} do
    curator_run.(%{status: :finished, stage_outcome: :done})

    {:ok, first} =
      Learnings.save_task_proposal(task, %{action: "add", rule: "Broadcast after commit", kind: "convention"})

    {:ok, _second} = Learnings.save_task_proposal(task, %{action: "add", rule: "Lock the row", kind: "convention"})
    assert {:error, {:learnings_open, 2}} = Pipeline.check_learnings(task)

    {:ok, _rejected} = Learnings.reject_learning_proposal(system_scope(), first)
    assert {:error, {:learnings_open, 1}} = Pipeline.check_learnings(task)
  end
end
