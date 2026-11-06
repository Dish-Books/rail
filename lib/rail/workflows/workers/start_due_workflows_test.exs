defmodule Rail.Workflows.Workers.StartDueWorkflowsTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  import ExUnit.CaptureLog

  alias Rail.Git
  alias Rail.Projects.Schemas.Project
  alias Rail.Workflows
  alias Rail.Workflows.Schemas.Workflow
  alias Rail.Workflows.Workers.StartDueWorkflows
  alias Rail.Workflows.Workers.StartWorkflow

  setup %{project: %{id: project_id} = project, github_project: %{id: github_id}} do
    # The seeded project's fetched default branch has two workflow files; the GitHub project's clone
    # never fetched one, so its branch cannot be listed.
    stub(Git, :list_default_branch_files, fn
      %Project{id: ^project_id}, ".rail/workflows" ->
        {:ok, [".rail/workflows/a-weekly.yml", ".rail/workflows/b-daily.yml"]}

      %Project{id: ^github_id}, ".rail/workflows" ->
        {:error, "fatal: Not a valid object name refs/remotes/origin/main"}
    end)

    stub(Git, :read_default_branch_file, fn
      %Project{id: ^project_id}, ".rail/workflows/a-weekly.yml" ->
        {:ok,
         """
         name: Dependency updates
         schedule: "0 9 * * 1"
         instructions: Update the dependencies.
         """}

      %Project{id: ^project_id}, ".rail/workflows/b-daily.yml" ->
        {:ok,
         """
         name: Flaky test sweep
         schedule: "0 6 * * *"
         instructions: Fix the flaky tests.
         """}
    end)

    stub(DateTime, :utc_now, fn -> ~U[2026-10-12 08:00:00.000000Z] end)
    {:ok, 2} = Workflows.sync_workflows(project)

    [%Workflow{id: weekly_id}, %Workflow{id: daily_id}] =
      Repo.all(from(w in Workflow, where: w.project_id == ^project.id, order_by: w.path))

    %{weekly_id: weekly_id, daily_id: daily_id}
  end

  test "syncs each cloned project, then queues one start per due workflow", %{
    project: project,
    github_project: github,
    weekly_id: weekly_id,
    daily_id: daily_id
  } do
    # A row gone from the table comes back only through a sync.
    Repo.delete_all(from(w in Workflow, where: w.id == ^daily_id))
    stub(Git, :git_repo?, fn path -> path in [project.clone_path, github.clone_path] end)
    stub(DateTime, :utc_now, fn -> ~U[2026-10-12 09:00:30.000000Z] end)

    log = capture_log(fn -> assert :ok = perform_job(StartDueWorkflows, %{}) end)

    assert log =~ "Could not read Test GitHub Project's workflows"

    assert [
             %Workflow{id: ^weekly_id},
             %Workflow{path: ".rail/workflows/b-daily.yml", next_run_at: ~U[2026-10-13 06:00:00Z]}
           ] =
             Repo.all(from(w in Workflow, where: w.project_id == ^project.id, order_by: w.path))

    assert [%Oban.Job{args: %{"workflow_id" => ^weekly_id}}] = all_enqueued(worker: StartWorkflow)
  end
end
