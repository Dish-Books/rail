defmodule Rail.Workflows.Actions.RunWorkflowNowTest do
  use Rail.DataCase, async: true

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Workflows
  alias Rail.Workflows.Schemas.Workflow

  setup %{project: project} do
    [workflow] = sync_workflow_files(project, %{".rail/workflows/dependency-updates.yml" => workflow_yaml()})
    stub(DateTime, :utc_now, fn -> ~U[2026-10-14 10:00:00.000000Z] end)
    stub(Pipeline, :start_task, fn %Issue{}, :plan -> {:ok, %Task{}} end)

    %{workflow: workflow}
  end

  test "Run now on a paused workflow opens one issue dated the day it was pressed, and the next start stays", %{
    workflow: %{id: workflow_id} = workflow
  } do
    {:ok, paused} = Workflows.set_workflow_paused(system_scope(), workflow, true)
    expect_linear_issue("TST-84")
    expect(Pipeline, :start_task, fn %Issue{workflow_id: ^workflow_id}, :plan -> {:ok, %Task{}} end)

    assert {:ok,
            %Issue{identifier: "TST-84", title: "Dependency updates 2026-10-14", workflow_id: ^workflow_id, id: issue_id}} =
             Workflows.run_workflow_now(system_scope(), paused)

    assert %Workflow{paused: true, next_run_at: ~U[2026-10-12 09:00:00Z]} = Repo.get!(Workflow, workflow_id)

    # No second tracker request is expected, so one would raise.
    assert {:error, {:unfinished, %Issue{id: ^issue_id}}} = Workflows.run_workflow_now(system_scope(), paused)
  end

  test "two presses racing from separate processes open one issue between them", %{
    workflow: %{id: workflow_id} = workflow
  } do
    expect_linear_issue("TST-85")

    presses = for _tab <- 1..2, do: Elixir.Task.async(fn -> Workflows.run_workflow_now(system_scope(), workflow) end)

    assert [{:ok, %Issue{id: issue_id}}, {:error, {:unfinished, %Issue{id: issue_id}}}] =
             Enum.sort_by(Elixir.Task.await_many(presses), &elem(&1, 0), :desc)

    assert [%Issue{id: ^issue_id}] = Repo.all(from(i in Issue, where: i.workflow_id == ^workflow_id))
  end

  test "a workflow on an inactive project opens nothing and says so" do
    {:ok, inactive} =
      Projects.create_project(system_scope(), %{
        name: "Ledger",
        github_repo: "example/ledger",
        github_installation_id: 1,
        default_branch: "main",
        key: "LED",
        clone_path: "/tmp/repos/ledger",
        active: false
      })

    [workflow] = sync_workflow_files(inactive, %{".rail/workflows/changelog.yml" => workflow_yaml()})

    assert {:error, :project_inactive} = Workflows.run_workflow_now(system_scope(), workflow)
  end

  test "an invalid workflow opens nothing", %{project: project} do
    [workflow] = sync_workflow_files(project, %{".rail/workflows/broken.yml" => "name: ["})

    assert {:error, :invalid} = Workflows.run_workflow_now(system_scope(), workflow)
  end

  test "a workflow whose file is gone opens nothing", %{project: project, workflow: stale} do
    sync_workflow_files(project, %{".rail/workflows/other.yml" => workflow_yaml()})

    assert {:error, :invalid} = Workflows.run_workflow_now(system_scope(), stale)
  end

  test "someone who is not an admin is refused", %{workflow: workflow} do
    assert {:error, :not_authorized} = Workflows.run_workflow_now(user_scope(), workflow)
  end
end
