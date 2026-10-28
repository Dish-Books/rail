defmodule Rail.Pipeline.Actions.StartTaskTest do
  use Rail.DataCase, async: true

  import Ecto.Query

  alias Rail.Git
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Round
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess

  setup %{project: project} do
    attrs = %{
      project_id: project.id,
      external_id: "lin_start_task",
      identifier: "STK-1",
      title: "Flaky test sweep 2026-10-10",
      description: "Make each flaky test deterministic.",
      state: :todo
    }

    %{attrs: attrs}
  end

  test "a hand-filed issue starts at Plan with one Plan run", %{project: project, attrs: attrs} do
    issue = %Issue{} |> Issue.tracker_changeset(attrs) |> Repo.insert!()
    {:ok, %Role{id: role_id}} = Roles.get_role(project_id: project.id, stage: :plan)

    expect(Git, :get_or_create_worktree, fn _project, task -> {:ok, task.worktree_path} end)
    expect(Tools, :start_os_process, fn %Run{} = run, _argv -> {:ok, %OsProcess{task_id: run.task_id, run: run}} end)

    assert {:ok, %Task{id: task_id, stage: :plan, runs: [%Run{role_id: ^role_id}]}} = Pipeline.start_task(issue)
    assert [%Run{role_id: ^role_id}] = Repo.all(from r in Run, where: r.task_id == ^task_id)
    assert [] = Repo.all(from r in Round, where: r.task_id == ^task_id)
  end

  test "an issue with every Plan step off starts at Engineer, with the issue as an approved round 1's ticket", %{
    project: project,
    attrs: attrs
  } do
    issue =
      %Issue{skipped_steps: [:product, :design, :architect]} |> Issue.tracker_changeset(attrs) |> Repo.insert!()

    {:ok, %Role{id: engineer_id}} = Roles.get_role(project_id: project.id, stage: :engineer)

    stub(Git, :get_or_create_worktree, fn _project, task -> {:ok, task.worktree_path} end)
    expect(Tools, :start_os_process, fn %Run{} = run, _argv -> {:ok, %OsProcess{task_id: run.task_id, run: run}} end)

    assert {:ok, %Task{id: task_id, stage: :engineer}} = Pipeline.start_task(issue)
    assert [%Run{role_id: ^engineer_id}] = Repo.all(from r in Run, where: r.task_id == ^task_id)

    assert [
             %Round{
               number: 1,
               plan: nil,
               approved_at: %DateTime{},
               approved_by_id: nil,
               ticket: %Round.Ticket{
                 title: "Flaky test sweep 2026-10-10",
                 description: "Make each flaky test deterministic."
               }
             }
           ] = Repo.all(from r in Round, where: r.task_id == ^task_id)
  end

  test "a second start of an Engineer task, as from another tab, makes no second round", %{attrs: attrs} do
    issue =
      %Issue{skipped_steps: [:product, :design, :architect]} |> Issue.tracker_changeset(attrs) |> Repo.insert!()

    stub(Git, :get_or_create_worktree, fn _project, task -> {:ok, task.worktree_path} end)
    stub(Tools, :start_os_process, fn %Run{} = run, _argv -> {:ok, %OsProcess{task_id: run.task_id, run: run}} end)

    assert {:ok, %Task{id: task_id}} = Pipeline.start_task(issue)
    assert {:ok, %Task{id: ^task_id}} = Pipeline.start_task(issue)
    assert [%Round{number: 1}] = Repo.all(from r in Round, where: r.task_id == ^task_id)
  end

  test "an Engineer start whose worktree cannot be made leaves the issue without a task", %{attrs: attrs} do
    issue =
      %Issue{skipped_steps: [:product, :design, :architect]} |> Issue.tracker_changeset(attrs) |> Repo.insert!()

    expect(Git, :get_or_create_worktree, fn _project, _task -> {:error, :clone_missing} end)
    reject(Tools, :start_os_process, 2)

    assert {:error, {:worktree_failed, :clone_missing}} = Pipeline.start_task(issue)
    assert [] = Repo.all(from t in Task, where: t.issue_id == ^issue.id)
  end
end
