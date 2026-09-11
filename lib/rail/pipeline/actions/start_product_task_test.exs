defmodule Rail.Pipeline.Actions.StartProductTaskTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Runs.Schemas.RoleRun
  alias Rail.Runs.Schemas.Run
  alias Rail.Users
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    scope = system_scope()

    {:ok, workspace} =
      Projects.upsert_linear_workspace(scope, %{
        name: "Start Product Workspace",
        external_id: "lin_ws_start_product",
        token: "lin_api_token_start_product",
        webhook_secret: "whsec_start_product"
      })

    {:ok, project} =
      Projects.create_project(scope, %{
        name: "Start Product Project 7001",
        github_repo: "org/start-product-7001",
        github_installation_id: 7001,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_start_product_7001",
        linear_team_key: "P7001",
        clone_path: create_temp_git_repo(),
        linear_state_ids: %{
          "triage" => "st_triage",
          "in_progress" => "st_in_progress"
        }
      })

    {:ok, role} =
      Roles.create_role(scope, project, %{
        stage: :product,
        name: "product role",
        model: "claude-3-7-sonnet",
        system_prompt: "You are the product agent."
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_start_product_1",
      "identifier" => "SPT-1",
      "title" => "Attachments follow their source document"
    })

    {:ok, issue} = Issues.capture_issue(scope, project, "Attachments follow their source document")

    %{scope: scope, project: project, role: role, issue: issue}
  end

  test "starts the product run for an issue that already has a task", %{project: project, role: role, issue: issue} do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")

    %Role{id: role_id} = role
    %Task{id: task_id} = insert_task(project, issue)
    scratch_dir = temp_scratch_dir()

    assert {:ok,
            %{
              task: %Task{id: ^task_id, stage_state: :running, worktree_path: worktree_path},
              role_run: %RoleRun{task_id: ^task_id, role_id: ^role_id, attempts: 1, status: :running},
              run: %Run{task_id: ^task_id}
            }} =
             Pipeline.start_product_task(issue,
               executable: System.find_executable("true") || "/usr/bin/true",
               skip_follower: true,
               scratch_dir: scratch_dir
             )

    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :dispatched}}
    assert byte_size(worktree_path) > 0

    content = scratch_dir |> Path.join("tickets/#{issue.identifier}.md") |> File.read!()

    assert content =~ "title: Attachments follow their source document"
    assert content =~ "priority: medium"
  end

  test "creates the task from an assigned issue, owned by the assignee", %{issue: issue} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_start_product_1",
        login: "start_product_user",
        email: "start_product_user@example.com"
      })

    user_id = user.id

    {:ok, %Issue{id: issue_id} = issue} =
      issue |> Issue.changeset(%{owner_user_id: user_id}, issue.project_id) |> Repo.update()

    LinearMock.mock_update_issue_success(%{"id" => issue.external_id})

    assert {:ok, %{task: %Task{issue_id: ^issue_id, owner_user_id: ^user_id, stage: :product}}} =
             Pipeline.start_product_task(issue,
               executable: System.find_executable("true") || "/usr/bin/true",
               skip_follower: true,
               scratch_dir: temp_scratch_dir()
             )
  end

  test "returns no_role_for_stage when the project has no product role", %{
    project: project,
    role: role,
    issue: issue
  } do
    {:ok, _deleted} = Roles.delete_role(system_scope(), role)
    insert_task(project, issue)

    assert {:error, {:no_role_for_stage, :product}} = Pipeline.start_product_task(issue)
  end

  test "marks the task failed when the worktree cannot be created", %{project: project, issue: issue} do
    not_a_repo = Path.join("/tmp", "not_a_repo_#{System.unique_integer([:positive])}")
    File.mkdir_p!(not_a_repo)
    on_exit(fn -> File.rm_rf(not_a_repo) end)

    {:ok, broken_project} = Projects.update_project(system_scope(), project, %{clone_path: not_a_repo})
    %Task{id: task_id} = insert_task(project, issue)

    assert {:error, {:worktree_failed, _reason}} =
             Pipeline.start_product_task(%{issue | project: broken_project})

    assert %Task{stage_state: stage_state} = Repo.get!(Task, task_id)
    assert stage_state != :running
  end

  defp insert_task(project, issue) do
    %Task{}
    |> Task.changeset(
      %{
        issue_id: issue.id,
        title: issue.title,
        description: issue.description,
        stage: :product,
        stage_state: :queued,
        worktree_name: "spt-#{System.unique_integer([:positive])}"
      },
      project.id
    )
    |> Repo.insert!()
  end

  defp temp_scratch_dir do
    dir = Path.join("/tmp", "rail_scratch_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end
end
