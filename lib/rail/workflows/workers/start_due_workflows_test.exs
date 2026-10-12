defmodule Rail.Workflows.Workers.StartDueWorkflowsTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  import ExUnit.CaptureLog

  alias Rail.Git
  alias Rail.Workflows.Schemas.Workflow
  alias Rail.Workflows.Workers.StartDueWorkflows
  alias Rail.Workflows.Workers.StartWorkflow

  test "syncs each cloned project, then queues one start per due workflow", %{project: project, github_project: github} do
    [%{id: weekly_id, project: %{clone_path: clone}}, %{id: daily_id}] =
      sync_workflow_files(project, %{
        ".rail/workflows/a-weekly.yml" => workflow_yaml(),
        ".rail/workflows/b-daily.yml" => workflow_yaml(%{"schedule" => "0 6 * * *"})
      })

    # A row gone from the table comes back only through a sync.
    Repo.delete_all(from(w in Workflow, where: w.id == ^daily_id))
    stub(Git, :git_repo?, fn path -> path in [clone, github.clone_path] end)
    stub(DateTime, :utc_now, fn -> ~U[2026-10-12 09:00:30.000000Z] end)

    log = capture_log(fn -> assert :ok = perform_job(StartDueWorkflows, %{}) end)

    # The GitHub project's clone is not on disk, so its branch cannot be listed.
    assert log =~ "Could not read Test GitHub Project's workflows"

    assert [
             %Workflow{id: ^weekly_id},
             %Workflow{path: ".rail/workflows/b-daily.yml", next_run_at: ~U[2026-10-13 06:00:00Z]}
           ] =
             Repo.all(from(w in Workflow, where: w.project_id == ^project.id, order_by: w.path))

    assert [%Oban.Job{args: %{"workflow_id" => ^weekly_id}}] = all_enqueued(worker: StartWorkflow)
  end
end
