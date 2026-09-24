defmodule Rail.Pipeline.Actions.StartTaskTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess

  setup %{project: project} do
    issue =
      %Issue{}
      |> Issue.linear_changeset(%{
        project_id: project.id,
        external_id: "lin_start_task",
        identifier: "STK-1",
        title: "Ticket already written",
        state: :todo
      })
      |> Repo.insert!()

    %{issue: issue}
  end

  test "starts the task at architect, running the architect role", %{project: project, issue: issue} do
    {:ok, backend} = Tools.create_backend(system_scope(), %{name: :claude, executable_path: "/usr/bin/true"})

    {:ok, %Role{id: role_id}} =
      Roles.create_role(system_scope(), project, %{
        backend_id: backend.id,
        stage: :architect,
        name: "architect role",
        model: "claude-3-7-sonnet",
        system_prompt: "You are the architect."
      })

    expect(Git, :get_or_create_worktree, fn _project, task -> {:ok, task.worktree_path} end)
    expect(Tools, :start_os_process, fn %Run{} = run, _argv -> {:ok, %OsProcess{task_id: run.task_id, run: run}} end)

    assert {:ok, %Task{stage: :architect, runs: [%Run{role_id: ^role_id}]}} = Pipeline.start_task(issue, :architect)
  end

  test "a project with no role for the stage leaves the issue without a task", %{issue: issue} do
    assert {:error, :role_not_found} = Pipeline.start_task(issue, :design)
    refute Repo.get_by(Task, issue_id: issue.id)
  end
end
