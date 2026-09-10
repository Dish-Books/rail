defmodule Rail.Pipeline.QueueTest do
  use Rail.DataCase, async: true

  alias Rail.Pipeline.Queue
  alias Rail.Pipeline.Schemas.Task

  test "returns empty list when role has no stage and counts active chats" do
    project = create_test_project()
    role = create_test_role(%{project_id: project.id, stage: nil, max_concurrent: 1})

    assert [] = Queue.eligible_tasks(project, role)
    assert Queue.current_live_runs_count(project, role) == 0

    _chat_task =
      create_test_task(%{
        project_id: project.id,
        stage: :engineer,
        stage_state: :idle,
        active_chat_role_id: role.id
      })

    assert Queue.current_live_runs_count(project, role) == 1
    assert Queue.available_slots(project, role) == 0
  end

  test "counts live runs and available slots accurately" do
    project = create_test_project()
    role = create_test_role(%{project_id: project.id, stage: :product, max_concurrent: 2})

    assert Queue.current_live_runs_count(project, role) == 0
    assert Queue.available_slots(project, role) == 2

    # 1. Running task for this stage
    _running_task =
      create_test_task(%{
        project_id: project.id,
        stage: :product,
        stage_state: :running
      })

    assert Queue.current_live_runs_count(project, role) == 1
    assert Queue.available_slots(project, role) == 1

    # 2. Task with active chat on this role
    _chat_task =
      create_test_task(%{
        project_id: project.id,
        stage: :engineer,
        stage_state: :idle,
        active_chat_role_id: role.id
      })

    assert Queue.current_live_runs_count(project, role) == 2
    assert Queue.available_slots(project, role) == 0

    # 3. Third task exceeds max_concurrent -> slots floors at 0
    _another_running =
      create_test_task(%{
        project_id: project.id,
        stage: :product,
        stage_state: :running
      })

    assert Queue.current_live_runs_count(project, role) == 3
    assert Queue.available_slots(project, role) == 0
    assert [] = Queue.eligible_tasks(project, role)
  end

  test "counts rebasing tasks as live runs for the engineer role" do
    project = create_test_project()
    engineer_role = create_test_role(%{project_id: project.id, stage: :engineer, max_concurrent: 1})
    product_role = create_test_role(%{project_id: project.id, stage: :product, max_concurrent: 1})

    _rebasing_task =
      create_test_task(%{
        project_id: project.id,
        stage: :ready_to_merge,
        stage_state: :running,
        is_rebasing: true
      })

    assert Queue.current_live_runs_count(project, engineer_role) == 1
    assert Queue.available_slots(project, engineer_role) == 0

    # Does not count towards product role
    assert Queue.current_live_runs_count(project, product_role) == 0
    assert Queue.available_slots(project, product_role) == 1
  end

  test "returns eligible tasks ordered by inserted_at FIFO up to slot limit" do
    project = create_test_project()
    role = create_test_role(%{project_id: project.id, stage: :product, max_concurrent: 2})

    %Task{id: t1_id} =
      create_test_task(%{
        project_id: project.id,
        stage: :product,
        stage_state: :queued,
        title: "First In"
      })

    %Task{id: t2_id} =
      create_test_task(%{
        project_id: project.id,
        stage: :product,
        stage_state: :queued,
        title: "Second In"
      })

    _t3 =
      create_test_task(%{
        project_id: project.id,
        stage: :product,
        stage_state: :queued,
        title: "Third In"
      })

    # Available slots = 2, so only t1 and t2 should be returned
    assert [
             %Task{id: ^t1_id},
             %Task{id: ^t2_id}
           ] = Queue.eligible_tasks(project, role)
  end

  test "excludes tasks with retry_after in the future and includes tasks with retry_after in the past" do
    project = create_test_project()
    role = create_test_role(%{project_id: project.id, stage: :product, max_concurrent: 5})

    future = DateTime.shift(DateTime.utc_now(), minute: 5)
    past = DateTime.shift(DateTime.utc_now(), minute: -5)

    _future_retry_task =
      create_test_task(%{
        project_id: project.id,
        stage: :product,
        stage_state: :queued,
        retry_after: future
      })

    past_retry_task =
      create_test_task(%{
        project_id: project.id,
        stage: :product,
        stage_state: :queued,
        retry_after: past
      })

    nil_retry_task =
      create_test_task(%{
        project_id: project.id,
        stage: :product,
        stage_state: :queued,
        retry_after: nil
      })

    eligible = Queue.eligible_tasks(project.id, role)
    eligible_ids = Enum.map(eligible, & &1.id)

    assert length(eligible) == 2
    assert past_retry_task.id in eligible_ids
    assert nil_retry_task.id in eligible_ids
  end

  test "matches rebasing tasks for engineer role" do
    project = create_test_project()
    engineer_role = create_test_role(%{project_id: project.id, stage: :engineer, max_concurrent: 2})

    %Task{id: rebase_task_id} =
      create_test_task(%{
        project_id: project.id,
        stage: :ready_to_merge,
        stage_state: :queued,
        is_rebasing: true
      })

    assert [%Task{id: ^rebase_task_id}] = Queue.eligible_tasks(project, engineer_role)
  end

  test "dispatches the design stage like any other" do
    project = create_test_project()
    role = create_test_role(%{project_id: project.id, stage: :design, max_concurrent: 1})

    task =
      create_test_task(%{
        project_id: project.id,
        stage: :design,
        stage_state: :queued
      })

    task_id = task.id

    assert Queue.current_live_runs_count(project, role) == 0
    assert [%Task{id: ^task_id}] = Queue.eligible_tasks(project, role)

    _running =
      create_test_task(%{
        project_id: project.id,
        stage: :design,
        stage_state: :running
      })

    assert Queue.current_live_runs_count(project, role) == 1
    assert Queue.available_slots(project, role) == 0
  end

  test "dispatches an off-pipeline stage like any other" do
    project = create_test_project()
    role = create_test_role(%{project_id: project.id, stage: :debugger, max_concurrent: 1})

    task = create_test_task(%{project_id: project.id, stage: :debugger, stage_state: :queued})
    task_id = task.id

    assert Queue.current_live_runs_count(project, role) == 0
    assert [%Task{id: ^task_id}] = Queue.eligible_tasks(project, role)

    _other_stage =
      create_test_task(%{project_id: project.id, stage: :engineer, stage_state: :queued})

    assert [%Task{id: ^task_id}] = Queue.eligible_tasks(project, role)
  end

  test "ignores tasks from other projects" do
    project1 = create_test_project()
    project2 = create_test_project()

    role1 = create_test_role(%{project_id: project1.id, stage: :product, max_concurrent: 2})

    _other_project_task =
      create_test_task(%{
        project_id: project2.id,
        stage: :product,
        stage_state: :queued
      })

    assert [] = Queue.eligible_tasks(project1, role1)
  end
end
