defmodule Rail.Pipeline.TaskActionRunnerTest do
  use Rail.DataCase, async: false

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Pipeline.TaskActionRunner
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo

  test "tracks running action, clears error on start, enforces single-flight, and finishes" do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")
    project = Repo.insert!(Project.factory())

    %Task{id: task_id} =
      Repo.insert!(%{
        Task.factory()
        | project_id: project.id,
          error: "Existing error to be cleared"
      })

    refute TaskActionRunner.is_busy?(task_id)
    assert TaskActionRunner.running_on(task_id) == nil

    # Start action
    assert :ok = TaskActionRunner.start_action(task_id, :merge)
    assert TaskActionRunner.is_busy?(task_id)
    assert TaskActionRunner.running_on(task_id) == :merge

    # Asserts that start_action immediately cleared old error
    assert %Task{error: nil} = Repo.get!(Task, task_id)
    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :action_started, kind: :merge}}

    # Single-flight: second start attempts return {:error, :busy}
    assert {:error, :busy} = TaskActionRunner.start_action(task_id, :merge)
    assert {:error, :busy} = TaskActionRunner.start_action(task_id, :rebase)

    # Finish action
    assert :ok = TaskActionRunner.finish_action(task_id, :merge, {:ok, :done})
    refute TaskActionRunner.is_busy?(task_id)
    assert TaskActionRunner.running_on(task_id) == nil
    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :action_finished, kind: :merge}}
  end

  test "finish_action with error or timeout writes error message to task" do
    project = Repo.insert!(Project.factory())
    %Task{id: task_id} = Repo.insert!(%{Task.factory() | project_id: project.id, error: nil})

    # Finish with standard error
    assert :ok = TaskActionRunner.start_action(task_id, :rebase)
    assert :ok = TaskActionRunner.finish_action(task_id, :rebase, {:error, "Rebase conflict failed"})
    assert %Task{error: "Rebase conflict failed"} = Repo.get!(Task, task_id)

    # Finish with timeout
    assert :ok = TaskActionRunner.start_action(task_id, :merge)
    assert :ok = TaskActionRunner.finish_action(task_id, :merge, {:error, :timeout})
    assert %Task{error: "Action merge timed out"} = Repo.get!(Task, task_id)
  end

  test "forget/2 releases lock without writing error" do
    project = Repo.insert!(Project.factory())
    %Task{id: task_id} = Repo.insert!(%{Task.factory() | project_id: project.id, error: nil})

    assert :ok = TaskActionRunner.start_action(task_id, :cleanup)
    assert TaskActionRunner.is_busy?(task_id)

    assert :ok = TaskActionRunner.forget(task_id)
    refute TaskActionRunner.is_busy?(task_id)
    assert %Task{error: nil} = Repo.get!(Task, task_id)
  end

  test "run/5 executes work single-flight and cleans up lock" do
    project = Repo.insert!(Project.factory())
    %Task{id: task_id} = Repo.insert!(%{Task.factory() | project_id: project.id, error: nil})

    assert {:ok, :success} =
             TaskActionRunner.run(task_id, :approve, fn ->
               {:ok, :success}
             end)

    refute TaskActionRunner.is_busy?(task_id)
  end

  test "run/5 enforces single-flight and rejects re-entry" do
    project = Repo.insert!(Project.factory())
    %Task{id: task_id} = Repo.insert!(%{Task.factory() | project_id: project.id, error: nil})

    assert :ok = TaskActionRunner.start_action(task_id, :cleanup)

    assert {:error, :busy} =
             TaskActionRunner.run(task_id, :cleanup, fn ->
               {:ok, :should_not_run}
             end)

    TaskActionRunner.forget(task_id)
  end

  test "run/5 handles timeout and failure" do
    project = Repo.insert!(Project.factory())
    %Task{id: task_id} = Repo.insert!(%{Task.factory() | project_id: project.id, error: nil})

    # Timeout
    assert {:error, :timeout} =
             TaskActionRunner.run(
               task_id,
               :merge,
               fn ->
                 Process.sleep(100)
                 {:ok, :slow}
               end,
               timeout: 10
             )

    assert %Task{error: "Action merge timed out"} = Repo.get!(Task, task_id)
    refute TaskActionRunner.is_busy?(task_id)

    # Failure
    assert {:error, "Network error"} =
             TaskActionRunner.run(task_id, :recheck_design, fn ->
               {:error, "Network error"}
             end)

    assert %Task{error: "Network error"} = Repo.get!(Task, task_id)
    refute TaskActionRunner.is_busy?(task_id)

    # Bare result (not wrapped in {:ok, _} or {:error, _})
    assert {:ok, :bare_result} =
             TaskActionRunner.run(task_id, :rebase, fn ->
               :bare_result
             end)

    # Process exit / crash
    Process.flag(:trap_exit, true)

    assert {:error, :crashed} =
             TaskActionRunner.run(task_id, :rebase, fn ->
               exit(:crashed)
             end)

    # Run on non-existent task_id exercises clear_task_error and set_task_error nil branches
    assert {:error, "failed"} =
             TaskActionRunner.run("tsk_nonexistent_999", :rebase, fn ->
               {:error, "failed"}
             end)
  end

  test "shows_progress? returns true only for merge, cleanup, mark_ready, and recheck_design" do
    assert TaskActionRunner.shows_progress?(:merge)
    assert TaskActionRunner.shows_progress?(:cleanup)
    assert TaskActionRunner.shows_progress?(:mark_ready)
    assert TaskActionRunner.shows_progress?(:recheck_design)

    refute TaskActionRunner.shows_progress?(:rebase)
    refute TaskActionRunner.shows_progress?(:comment)
    refute TaskActionRunner.shows_progress?(:approve)
    refute TaskActionRunner.shows_progress?(:send_back)
    refute TaskActionRunner.shows_progress?(:retry)
    refute TaskActionRunner.shows_progress?(:dispatch)
    refute TaskActionRunner.shows_progress?(:cancel)
    refute TaskActionRunner.shows_progress?(:other)
    refute TaskActionRunner.shows_progress?("non-atom")
    refute TaskActionRunner.shows_progress?(nil)
  end

  test "timeout_for returns expected defaults or overrides" do
    assert TaskActionRunner.timeout_for(:merge) == 180_000
    assert TaskActionRunner.timeout_for(:cleanup) == 120_000
    assert TaskActionRunner.timeout_for(:mark_ready) == 60_000
    assert TaskActionRunner.timeout_for(:recheck_design) == 60_000
    assert TaskActionRunner.timeout_for(:rebase) == 60_000
    assert TaskActionRunner.timeout_for(:approve) == 60_000

    assert TaskActionRunner.timeout_for(:merge, timeout: 5_000) == 5_000
  end
end
