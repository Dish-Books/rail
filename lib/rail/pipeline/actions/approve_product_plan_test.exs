defmodule Rail.Pipeline.Actions.ApproveProductPlanTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Roles
  alias Rail.Runs
  alias Rail.Runs.Schemas.OsProcess
  alias Rail.Runs.Schemas.Run
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    scope = system_scope()

    {:ok, backend} = Rail.Tools.create_backend(scope, %{name: :claude, executable_path: "/usr/bin/true"})

    {:ok, workspace} =
      Projects.upsert_linear_workspace(scope, %{
        name: "Approve Plan Workspace",
        external_id: "lin_ws_approve_plan",
        token: "lin_api_token_approve_plan",
        webhook_secret: "whsec_approve_plan"
      })

    {:ok, project} =
      Projects.create_project(scope, %{
        name: "Approve Plan Project",
        github_repo: "org/approve-plan",
        github_installation_id: 45_001,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_approve_plan",
        linear_team_key: "APV",
        default_branch: "main",
        clone_path: "/tmp/repos/approve-plan",
        linear_state_ids: %{"triage" => "st_triage"}
      })

    roles =
      Map.new([:product, :design, :architect, :engineer, :review, :qa, :qa_lead, :demo], fn stage ->
        {:ok, role} =
          Roles.create_role(scope, project, %{
            backend_id: backend.id,
            stage: stage,
            name: "#{stage} role",
            model: "claude-3-7-sonnet",
            system_prompt: "You are the #{stage} agent."
          })

        {stage, role}
      end)

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_approve_plan_1",
      "identifier" => "APV-1",
      "title" => "Approve Plan Issue"
    })

    {:ok, issue} = Issues.create_issue(project, %{description: "Approve Plan Issue"})
    {:ok, task} = Pipeline.create_task(issue, :product)

    %{project: project, task: task, roles: roles}
  end

  setup %{task: task, roles: roles} do
    scratch = Path.join(System.tmp_dir!(), "approve_plan_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(scratch, "tickets"))
    on_exit(fn -> File.rm_rf(scratch) end)

    File.write!(
      Path.join([scratch, "tickets", "APV-1.md"]),
      "---\ntitle: The approved ticket\n---\n\nWhat the product agent wrote.\n"
    )

    {:ok, task} =
      Pipeline.update_task(task, %{scratch_path: scratch, worktree_path: create_temp_git_repo()})

    {:ok, run} =
      Runs.create_run(%{
        task_id: task.id,
        role_id: roles[:product].id,
        status: :finished,
        started_at: DateTime.utc_now()
      })

    %{task: task, scratch: scratch, run: Repo.preload(run, task: [:issue, :runs])}
  end

  test "publishes the ticket the product run wrote and hands it to design", %{
    task: task,
    run: run,
    roles: roles
  } do
    stub(Runs, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned, task: task}} end)

    assert {:ok, %Run{stage_outcome: :done}} = Pipeline.approve_product_plan(run)

    assert %Task{stage: :design} = Repo.reload!(task)

    assert %Issue{title: "The approved ticket", description: "What the product agent wrote."} =
             Repo.get!(Issue, task.issue_id)

    assert Repo.get_by(Run, task_id: task.id, role_id: roles[:design].id)
  end

  test "skipping designs hands the ticket straight to the architect", %{task: task, run: run, roles: roles} do
    stub(Runs, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned, task: task}} end)

    assert {:ok, %Run{}} = Pipeline.approve_product_plan(run, skip_design: true)

    assert %Task{stage: :architect} = Repo.reload!(task)
    assert Repo.get_by(Run, task_id: task.id, role_id: roles[:architect].id)
  end

  test "a ticket already approved is not approved twice", %{run: run} do
    {:ok, approved} = run |> Run.changeset(%{stage_outcome: :done}) |> Repo.update()

    assert {:error, :already_approved} = Pipeline.approve_product_plan(Repo.preload(approved, task: [:issue, :runs]))
  end

  test "nothing is approved while something on the task is still working", %{task: task, run: run, roles: roles} do
    {:ok, _running} =
      Runs.create_run(%{
        task_id: task.id,
        role_id: roles[:engineer].id,
        status: :running,
        started_at: DateTime.utc_now()
      })

    assert {:error, :stage_running} =
             Pipeline.approve_product_plan(Repo.preload(run, [task: [:issue, :runs]], force: true))
  end

  test "a task past product has nothing left to approve", %{task: task, run: run} do
    {:ok, _task} = Pipeline.update_task(task, %{stage: :engineer})

    assert {:error, {:invalid_stage, :engineer}} =
             Pipeline.approve_product_plan(Repo.preload(run, [task: [:issue, :runs]], force: true))
  end

  test "a task with no issue has nowhere to publish the ticket", %{task: task, run: run} do
    {:ok, _task} = Pipeline.update_task(task, %{issue_id: nil})

    assert {:error, :no_issue} =
             Pipeline.approve_product_plan(Repo.preload(run, [task: [:issue, :runs]], force: true))
  end
end
