defmodule Rail.Pipeline.Actions.StartProductRunTest do
  use Rail.DataCase, async: true

  import Ecto.Query

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess
  alias Rail.Users
  alias Rail.Users.Schemas.User
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    {:ok, backend} =
      Tools.create_backend(system_scope(), %{name: :claude, executable_path: "/usr/bin/true"})

    scope = system_scope()

    {:ok, project} =
      Projects.create_project(scope, %{
        name: "Start Product Project 7001",
        github_repo: "org/start-product-7001",
        github_installation_id: 7001,
        linear_workspace: %{
          name: "Start Product Workspace",
          external_id: "lin_ws_start_product",
          token: "lin_api_token_start_product",
          webhook_secret: "whsec_start_product"
        },
        linear_team_id: "team_start_product_7001",
        linear_team_key: "P7001",
        default_branch: "main",
        clone_path: create_temp_git_repo(),
        linear_state_ids: %{
          "triage" => "st_triage",
          "in_progress" => "st_in_progress"
        }
      })

    {:ok, role} =
      Roles.create_role(scope, project, %{
        backend_id: backend.id,
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

    {:ok, issue} = Issues.create_issue(project, %{description: "Attachments follow their source document"})

    {:ok, task} = Pipeline.create_task(issue, :product)

    %{scope: scope, project: project, role: role, issue: issue, task: task}
  end

  test "starts the product run for a task", %{
    role: %Role{id: role_id},
    issue: issue,
    task: %Task{id: task_id} = task
  } do
    expect(Tools, :start_os_process, fn %Run{task_id: ^task_id, role_id: ^role_id, status: :running} = run, argv ->
      assert ["-p", prompt, "--model", "claude-3-7-sonnet", "--effort", "high" | _flags] = argv
      assert prompt =~ "tickets/#{issue.identifier}.md"
      assert "--system-prompt" in argv

      {:ok, %OsProcess{task_id: task_id, run: run, task: task}}
    end)

    assert {:ok,
            %OsProcess{
              task_id: ^task_id,
              task: %Task{id: ^task_id},
              run: %Run{task_id: ^task_id, role_id: ^role_id}
            }} =
             Pipeline.start_product_run(task)

    assert %Task{worktree_path: worktree_path} = Repo.get!(Task, task_id)
    assert byte_size(worktree_path) > 0

    content =
      task.scratch_path
      |> Path.join("tickets/#{issue.identifier}.md")
      |> File.read!()

    assert content =~ "title: Attachments follow their source document"
    assert content =~ "priority: medium"
  end

  test "leaves the owner on the issue the task links to", %{issue: issue, task: task} do
    {:ok, %User{id: user_id}} =
      Users.register_oauth_user(%{
        github_id: "gh_start_product_1",
        login: "start_product_user",
        email: "start_product_user@example.com"
      })

    {:ok, %Issue{id: issue_id}} =
      issue |> Issue.changeset(%{owner_user_id: user_id}) |> Repo.update()

    expect(Tools, :start_os_process, fn %Run{} = run, _argv ->
      {:ok, %OsProcess{task_id: task.id, run: run, task: task}}
    end)

    assert {:ok, %OsProcess{task: %Task{issue_id: ^issue_id, stage: :product} = task}} =
             Pipeline.start_product_run(task)

    # The owner lives on the issue; the task only links to it.
    assert %Issue{owner_user_id: ^user_id} = Repo.get!(Issue, task.issue_id)
  end

  test "returns role_not_found when the project has no product role", %{role: role, task: task} do
    {:ok, _deleted} = Roles.delete_role(system_scope(), role)

    assert {:error, :role_not_found} = Pipeline.start_product_run(task)
  end

  test "returns worktree_failed when the worktree cannot be created", %{
    project: project,
    task: %Task{id: task_id} = task
  } do
    not_a_repo = Path.join("/tmp", "not_a_repo_#{System.unique_integer([:positive])}")
    File.mkdir_p!(not_a_repo)
    on_exit(fn -> File.rm_rf(not_a_repo) end)

    {:ok, _broken_project} = Projects.update_project(system_scope(), project, %{clone_path: not_a_repo})

    assert {:error, {:worktree_failed, _reason}} = Pipeline.start_product_run(task)

    assert %Task{} = Repo.get!(Task, task_id)
    refute Repo.exists?(from r in Run, where: r.task_id == ^task_id)
  end
end
