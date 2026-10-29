defmodule Rail.Workflows.Workers.StartWorkflowTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  import ExUnit.CaptureLog

  alias Rail.Issues.Schemas.Issue
  alias Rail.Workflows.Schemas.Workflow
  alias Rail.Workflows.Schemas.WorkflowDefinition
  alias Rail.Workflows.Workers.StartWorkflow

  setup %{project: project} do
    workflow =
      Repo.insert!(%Workflow{
        project_id: project.id,
        path: ".rail/workflows/dependency-updates.yml",
        definition: %WorkflowDefinition{
          name: "Dependency updates",
          schedule: "0 9 * * 1",
          instructions: "Update the dependencies."
        },
        next_run_at: ~U[2026-10-12 09:00:00Z]
      })

    stub(DateTime, :utc_now, fn -> ~U[2026-10-12 09:00:30.000000Z] end)

    %{workflow: workflow}
  end

  test "the job starts its workflow, and a later one finding its issue unfinished opens nothing", %{
    workflow: %{id: workflow_id}
  } do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_TST-84", "identifier" => "TST-84", "title" => "Dependency updates 2026-10-12"}
          }
        }
      })
    end)

    assert :ok = perform_job(StartWorkflow, %{workflow_id: workflow_id})
    assert [%Issue{identifier: "TST-84"}] = Repo.all(from(i in Issue, where: i.workflow_id == ^workflow_id))

    stub(DateTime, :utc_now, fn -> ~U[2026-10-19 09:00:30.000000Z] end)
    assert :ok = perform_job(StartWorkflow, %{workflow_id: workflow_id})
    assert [_one] = Repo.all(from(i in Issue, where: i.workflow_id == ^workflow_id))
  end

  test "a job for a workflow not due finishes quietly", %{workflow: %{id: workflow_id}} do
    stub(DateTime, :utc_now, fn -> ~U[2026-10-12 08:30:00.000000Z] end)

    # Other async tests log at the same moment, so only this workflow's line is looked for.
    log = capture_log(fn -> assert :ok = perform_job(StartWorkflow, %{workflow_id: workflow_id}) end)
    refute log =~ "dependency-updates.yml"
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
