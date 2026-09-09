defmodule Rail.Pipeline.Actions.ReleaseBlockedStageTest do
  use Rail.DataCase, async: true

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Runs.Schemas.Run

  test "releases to running state when active process is running" do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")

    project = create_test_project()
    role = create_test_role(%{project_id: project.id, stage: :engineer})
    q = create_test_question(%{status: :pending})

    %Task{id: task_id} =
      create_test_task(%{project_id: project.id, stage: :engineer, stage_state: :blocked, question_id: q.id})

    role_run = create_test_role_run(%{task_id: task_id, role_id: role.id, status: :blocked_on_input})

    _run =
      Repo.insert!(%Run{
        role_run_id: role_run.id,
        task_id: task_id,
        kind: :stage,
        status: :running,
        stream_path: "/tmp/fake_stream",
        node: "node_test",
        boot_id: "boot_test",
        started_at: DateTime.utc_now()
      })

    assert {:ok, %Task{stage_state: :running, question_id: nil}} =
             Pipeline.release_blocked_stage(task_id)

    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :stage_released}}
  end

  test "resumes stage settlement and advances stage when finished run had exit_code 0" do
    project = create_test_project()
    role = create_test_role(%{project_id: project.id, stage: :engineer})
    q = create_test_question(%{status: :pending})
    task = create_test_task(%{project_id: project.id, stage: :engineer, stage_state: :blocked, question_id: q.id})

    role_run =
      create_test_role_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :blocked_on_input,
        exit_code: 0
      })

    _run =
      Repo.insert!(%Run{
        role_run_id: role_run.id,
        task_id: task.id,
        kind: :stage,
        status: :finished,
        stream_path: "/tmp/fake_stream_0",
        node: "node_test",
        boot_id: "boot_test",
        started_at: DateTime.utc_now()
      })

    assert {:ok, %Task{stage: :review, stage_state: :queued, question_id: nil}} =
             Pipeline.release_blocked_stage(task)
  end

  test "sets failed state when finished run had non-zero exit_code" do
    project = create_test_project()
    role = create_test_role(%{project_id: project.id, stage: :engineer})
    q = create_test_question(%{status: :pending})
    task = create_test_task(%{project_id: project.id, stage: :engineer, stage_state: :blocked, question_id: q.id})

    role_run =
      create_test_role_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :blocked_on_input,
        exit_code: 1
      })

    _run =
      Repo.insert!(%Run{
        role_run_id: role_run.id,
        task_id: task.id,
        kind: :stage,
        status: :finished,
        stream_path: "/tmp/fake_stream_err",
        node: "node_test",
        boot_id: "boot_test",
        started_at: DateTime.utc_now()
      })

    assert {:ok, %Task{stage_state: :failed, question_id: nil}} =
             Pipeline.release_blocked_stage(task)
  end

  test "falls back to awaiting_approval when no run is behind the task" do
    project = create_test_project()
    q = create_test_question(%{status: :pending})
    task = create_test_task(%{project_id: project.id, stage_state: :blocked, question_id: q.id})

    assert {:ok, %Task{stage_state: :awaiting_approval, question_id: nil}} =
             Pipeline.release_blocked_stage(task)
  end

  test "validates scope authorization and task existence" do
    assert {:error, :not_authorized} = Pipeline.release_blocked_stage(%Rail.Scope{}, "tsk_any")
    assert {:error, :not_found} = Pipeline.release_blocked_stage("tsk_missing")
    assert {:error, :not_found} = Pipeline.release_blocked_stage(123)

    task = create_test_task(%{stage_state: :blocked})
    user_scope = %Rail.Scope{user: %{id: "usr_test"}}
    assert {:ok, %Task{stage_state: :awaiting_approval}} = Pipeline.release_blocked_stage(user_scope, task.id)
  end
end
