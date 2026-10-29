defmodule Rail.Workflows.Workers.StartWorkflowTaskTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Git
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess
  alias Rail.Workflows.Schemas.Workflow
  alias Rail.Workflows.Schemas.WorkflowDefinition
  alias Rail.Workflows.Workers.StartWorkflowTask

  setup %{project: project} do
    # A role's prompt is read from the project's clone, which another test may have made, so reading it here
    # would spawn git: these see no prompt file on the default branch, as when there is no clone.
    stub(Git, :read_default_branch_file, fn _project, path -> {:error, "fatal: path '#{path}' does not exist"} end)

    Phoenix.PubSub.subscribe(Rail.PubSub, "workflows")

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

    issue =
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: project.id,
        workflow_id: workflow.id,
        external_id: "lin_TST-84",
        identifier: "TST-84",
        title: "Dependency updates 2026-10-12",
        description: "Update the dependencies.",
        state: :triage
      })
      |> Repo.insert!()

    %{issue: issue}
  end

  test "the job starts the issue's task at Plan and announces it", %{
    project: %{id: project_id},
    issue: %{id: issue_id}
  } do
    expect(Git, :get_or_create_worktree, fn _project, task -> {:ok, task.worktree_path} end)
    expect(Tools, :start_os_process, fn %Run{} = run, _argv -> {:ok, %OsProcess{task_id: run.task_id, run: run}} end)

    assert :ok = perform_job(StartWorkflowTask, %{issue_id: issue_id})

    assert [%Task{stage: :plan, runs: [%Run{}]}] =
             Repo.all(from(t in Task, where: t.issue_id == ^issue_id, preload: :runs))

    assert_receive {:workflows_changed, ^project_id}
  end

  test "an issue whose workflow turned every Plan step off starts its task at Engineer, with no Plan run", %{
    project: project,
    issue: %{id: issue_id} = issue
  } do
    issue |> Ecto.Changeset.change(skipped_steps: [:product, :design, :architect]) |> Repo.update!()
    {:ok, %{id: engineer_id}} = Rail.Roles.get_role(project_id: project.id, stage: :engineer)

    stub(Git, :get_or_create_worktree, fn _project, task -> {:ok, task.worktree_path} end)
    expect(Tools, :start_os_process, fn %Run{} = run, _argv -> {:ok, %OsProcess{task_id: run.task_id, run: run}} end)

    assert :ok = perform_job(StartWorkflowTask, %{issue_id: issue_id})

    assert [%Task{stage: :engineer, runs: [%Run{role_id: ^engineer_id}]}] =
             Repo.all(from(t in Task, where: t.issue_id == ^issue_id, preload: :runs))
  end

  test "a start that rolled back fails the job, so Oban tries again", %{
    project: %{id: project_id},
    issue: %{id: issue_id}
  } do
    expect(Git, :get_or_create_worktree, fn _project, _task -> {:error, :clone_missing} end)

    assert {:error, {:worktree_failed, :clone_missing}} = perform_job(StartWorkflowTask, %{issue_id: issue_id})
    assert [] = Repo.all(from(t in Task, where: t.issue_id == ^issue_id))
    assert_receive {:workflows_changed, ^project_id}
  end

  test "a spawn refused after the task is committed is not retried", %{issue: %{id: issue_id}} do
    expect(Git, :get_or_create_worktree, fn _project, task -> {:ok, task.worktree_path} end)
    expect(Tools, :start_os_process, fn %Run{}, _argv -> {:error, :dispatch_disabled} end)

    assert :ok = perform_job(StartWorkflowTask, %{issue_id: issue_id})
    assert [%Task{stage: :plan}] = Repo.all(from(t in Task, where: t.issue_id == ^issue_id))
  end

  test "an issue that already has a task is left alone", %{issue: %{id: issue_id} = issue} do
    {:ok, %Task{id: task_id}} = issue |> Repo.preload(:project) |> Pipeline.create_task(:plan)
    reject(Pipeline, :start_task, 1)

    assert :ok = perform_job(StartWorkflowTask, %{issue_id: issue_id})
    assert [%Task{id: ^task_id}] = Repo.all(from(t in Task, where: t.issue_id == ^issue_id))
  end

  test "an issue finished before the job ran is left alone", %{issue: %{id: issue_id} = issue} do
    issue |> Issue.tracker_changeset(%{state: :done}) |> Repo.update!()
    reject(Pipeline, :start_task, 1)

    assert :ok = perform_job(StartWorkflowTask, %{issue_id: issue_id})
    assert [] = Repo.all(from(t in Task, where: t.issue_id == ^issue_id))
  end

  test "a deleted issue finishes the job", %{issue: %{id: issue_id} = issue} do
    Repo.delete!(issue)
    reject(Pipeline, :start_task, 1)

    assert :ok = perform_job(StartWorkflowTask, %{issue_id: issue_id})
  end

  test "each retry waits two minutes longer than the last" do
    assert StartWorkflowTask.backoff(%Oban.Job{attempt: 2}) == 240
  end
end
