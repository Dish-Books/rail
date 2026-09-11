defmodule Rail.Pipeline.Actions.StartDesignTaskTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Runs.Schemas.RoleRun
  alias Rail.Runs.Schemas.Run
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    {:ok, backend} =
      Rail.Backends.create_backend(system_scope(), %{name: :claude, executable_path: "/usr/bin/true"})

    scope = system_scope()

    {:ok, workspace} =
      Projects.upsert_linear_workspace(scope, %{
        name: "Start Design Workspace",
        external_id: "lin_ws_start_design",
        token: "lin_api_token_start_design",
        webhook_secret: "whsec_start_design"
      })

    {:ok, project} =
      Projects.create_project(scope, %{
        name: "Start Design Project 7201",
        github_repo: "org/start-design-7201",
        github_installation_id: 7201,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_start_design_7201",
        linear_team_key: "P7201",
        default_branch: "main",
        clone_path: create_temp_git_repo(),
        linear_state_ids: %{"triage" => "st_triage", "in_progress" => "st_in_progress"}
      })

    {:ok, role} =
      Roles.create_role(scope, project, %{
        backend_id: backend.id,
        stage: :design,
        name: "design role",
        model: "claude-3-7-sonnet",
        system_prompt: "You are the design agent."
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_start_design_1",
      "identifier" => "SDT-1",
      "title" => "Attachments follow their source document"
    })

    {:ok, issue} = Issues.capture_issue(scope, project, "Attachments follow their source document")

    %{scope: scope, project: project, role: role, issue: issue}
  end

  test "moves the task to design and spawns the design run", %{project: project, role: role, issue: issue} do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")

    %Role{id: role_id} = role
    %Task{id: task_id} = task = insert_task(project, issue)
    scratch_dir = temp_scratch_dir()

    assert {:ok,
            %{
              task: %Task{id: ^task_id, stage: :design, stage_state: :running, worktree_path: worktree_path},
              role_run: %RoleRun{task_id: ^task_id, role_id: ^role_id, attempts: 1, status: :running},
              run: %Run{task_id: ^task_id}
            }} =
             Pipeline.start_design_task(task,
               scratch_dir: scratch_dir,
               executable: System.find_executable("true") || "/usr/bin/true",
               skip_follower: true
             )

    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :dispatched}}
    assert byte_size(worktree_path) > 0
    assert File.dir?(Path.join(scratch_dir, "design"))

    content = scratch_dir |> Path.join("tickets/#{issue.identifier}.md") |> File.read!()
    assert content =~ "title: Attachments follow their source document"
  end

  test "returns role_not_found when the project has no design role", %{
    project: project,
    role: role,
    issue: issue
  } do
    {:ok, _deleted} = Roles.delete_role(system_scope(), role)
    task = insert_task(project, issue)

    assert {:error, :role_not_found} = Pipeline.start_design_task(task)

    assert %Task{stage: :product} = Repo.get!(Task, task.id)
  end

  test "returns not_found for an unknown task" do
    assert {:error, :not_found} = Pipeline.start_design_task("tsk_000000000000000000000000")
  end

  defp insert_task(project, issue) do
    name = "sdt-#{System.unique_integer([:positive])}"

    %Task{}
    |> Task.changeset(
      %{
        issue_id: issue.id,
        title: issue.title,
        description: issue.description,
        stage: :product,
        stage_state: :awaiting_approval,
        worktree_name: name,
        worktree_path: Path.join(project.clone_path, ".worktrees/#{name}")
      },
      project.id
    )
    |> Repo.insert!()
  end

  defp temp_scratch_dir do
    dir = Path.join(System.tmp_dir!(), "rail_scratch_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end
end
