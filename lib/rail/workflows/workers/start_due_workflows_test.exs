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

  setup %{project: project} do
    remote = create_temp_git_repo(prefix: "rail_wf_remote")
    File.mkdir_p!(Path.join(remote, ".rail/workflows"))

    File.write!(Path.join(remote, ".rail/workflows/a-weekly.yml"), """
    name: Dependency updates
    schedule: "0 9 * * 1"
    instructions: Update the dependencies.
    """)

    File.write!(Path.join(remote, ".rail/workflows/b-daily.yml"), """
    name: Flaky test sweep
    schedule: "0 6 * * *"
    instructions: Fix the flaky tests.
    """)

    git!(remote, ["add", "."])
    git!(remote, ["commit", "-m", "workflows"])
    clone = create_temp_git_repo(prefix: "rail_wf_clone")
    git!(clone, ["remote", "add", "origin", remote])
    git!(clone, ["fetch", "origin", "main"])

    # The seeded project's clone is not on disk, so it is pointed at this one.
    Repo.update_all(from(p in Project, where: p.id == ^project.id), set: [clone_path: clone])
    stub(DateTime, :utc_now, fn -> ~U[2026-10-12 08:00:00.000000Z] end)
    {:ok, 2} = Workflows.sync_workflows(%{project | clone_path: clone})

    [%Workflow{id: weekly_id}, %Workflow{id: daily_id}] =
      Repo.all(from(w in Workflow, where: w.project_id == ^project.id, order_by: w.path))

    %{weekly_id: weekly_id, daily_id: daily_id, clone: clone}
  end

  test "syncs each cloned project, then queues one start per due workflow", %{
    project: project,
    github_project: github,
    weekly_id: weekly_id,
    daily_id: daily_id,
    clone: clone
  } do
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
