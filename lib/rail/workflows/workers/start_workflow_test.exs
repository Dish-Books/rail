defmodule Rail.Workflows.Workers.StartWorkflowTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  import ExUnit.CaptureLog

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Workflows.Schemas.Workflow
  alias Rail.Workflows.Workers.StartWorkflow

  setup %{project: project} do
    [workflow] = sync_workflow_files(project, %{".rail/workflows/dependency-updates.yml" => workflow_yaml()})
    stub(DateTime, :utc_now, fn -> ~U[2026-10-12 09:00:30.000000Z] end)
    stub(Pipeline, :start_task, fn %Issue{}, :plan -> {:ok, %Task{}} end)

    %{workflow: workflow}
  end

  test "the job starts its workflow, and a later one finding its issue unfinished opens nothing", %{
    workflow: %{id: workflow_id}
  } do
    expect_linear_issue("TST-84")

    assert :ok = perform_job(StartWorkflow, %{workflow_id: workflow_id})
    assert [%Issue{identifier: "TST-84"}] = Repo.all(from(i in Issue, where: i.workflow_id == ^workflow_id))

    stub(DateTime, :utc_now, fn -> ~U[2026-10-19 09:00:30.000000Z] end)
    assert :ok = perform_job(StartWorkflow, %{workflow_id: workflow_id})
    assert [_one] = Repo.all(from(i in Issue, where: i.workflow_id == ^workflow_id))
  end

  test "a job for a workflow not due finishes quietly", %{workflow: %{id: workflow_id}} do
    stub(DateTime, :utc_now, fn -> ~U[2026-10-12 08:30:00.000000Z] end)

    assert capture_log(fn -> assert :ok = perform_job(StartWorkflow, %{workflow_id: workflow_id}) end) == ""
    assert %Workflow{next_run_at: ~U[2026-10-12 09:00:00Z]} = Repo.get!(Workflow, workflow_id)
  end

  test "a tracker error is logged, and the start waits for the next due time", %{workflow: %{id: workflow_id}} do
    Req.Test.expect(Rail.Linear, fn conn -> conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{}) end)

    log = capture_log(fn -> assert :ok = perform_job(StartWorkflow, %{workflow_id: workflow_id}) end)

    assert log =~ ".rail/workflows/dependency-updates.yml in Test Project opened nothing: {:linear_api_error, 500"
  end

  test "a second job for the same workflow is not queued while the first is pending", %{workflow: %{id: workflow_id}} do
    {:ok, %Oban.Job{conflict?: false}} = Oban.insert(StartWorkflow.new(%{workflow_id: workflow_id}))
    {:ok, %Oban.Job{conflict?: true}} = Oban.insert(StartWorkflow.new(%{workflow_id: workflow_id}))

    assert [_one] = all_enqueued(worker: StartWorkflow, args: %{workflow_id: workflow_id})
  end
end
