defmodule Rail.Pipeline.Actions.StartProductRunTest do
  use Rail.DataCase, async: true

  import Ecto.Query

  alias Rail.Issues
  alias Rail.Issues.Schemas.Comment
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

  # Its own project, because starting a run adds a worktree to a real clone.
  setup %{project: %{linear_workspace_id: workspace_id}} do
    {:ok, backend} =
      Tools.create_backend(system_scope(), %{name: :claude, executable_path: "/usr/bin/true"})

    scope = system_scope()
    clone_path = create_temp_git_repo()
    git!(clone_path, ["remote", "add", "origin", create_temp_git_repo(prefix: "rail_start_product_remote")])
    Req.Test.stub(Rail.GitHub.Client, &Req.Test.json(&1, %{"token" => "ghs_token"}))

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "lin_team_id"}]}}})
    end)

    {:ok, project} =
      Projects.create_project(scope, %{
        name: "Start Product Project",
        github_repo: "org/start-product",
        github_installation_id: 7001,
        linear_team_key: "SPT",
        default_branch: "main",
        clone_path: clone_path,
        linear_state_ids: %{"triage" => "st_triage", "in_progress" => "st_in_progress"},
        linear_workspace_id: workspace_id
      })

    {:ok, role} =
      Roles.create_role(scope, project, %{
        backend_id: backend.id,
        stage: :product,
        name: "product role",
        model: "claude-3-7-sonnet",
        system_prompt: "You are the product agent."
      })

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{
              "id" => "lin_start_product_1",
              "identifier" => "SPT-1",
              "title" => "Attachments follow their source document"
            }
          }
        }
      })
    end)

    {:ok, issue} =
      Issues.create_issue(system_scope(), project, %{description: "Attachments follow their source document"})

    %{scope: scope, project: project, role: role, issue: issue}
  end

  test "creates the task for an issue and starts its product run", %{
    role: %Role{id: role_id},
    issue: %Issue{id: issue_id} = issue
  } do
    Repo.insert!(%Comment{
      issue_id: issue_id,
      external_id: "lin_comment_start_product",
      author_name: "Ana",
      body: "It only happens on Sysco bills."
    })

    expect(Tools, :start_os_process, fn %Run{role_id: ^role_id, status: :running} = run, argv ->
      assert ["-p", prompt, "--model", "claude-3-7-sonnet", "--effort", "high" | _flags] = argv
      assert prompt =~ "tickets/#{issue.identifier}.md"
      assert prompt =~ ~s(<comment author="Ana")
      assert prompt =~ "It only happens on Sysco bills."
      assert "--append-system-prompt" in argv

      {:ok, %OsProcess{task_id: run.task_id, run: run, task: run.task}}
    end)

    assert {:ok,
            %OsProcess{
              task_id: task_id,
              task: %Task{id: task_id, issue_id: ^issue_id},
              run: %Run{task_id: task_id, role_id: ^role_id}
            }} =
             Pipeline.start_product_run(issue)

    assert %Task{worktree_path: worktree_path} = task = Repo.get!(Task, task_id)
    assert File.dir?(worktree_path)

    content =
      task.scratch_path
      |> Path.join("tickets/#{issue.identifier}.md")
      |> File.read!()

    assert content =~ "title: Attachments follow their source document"
    assert content =~ "priority: medium"
  end

  test "leaves the owner on the issue the task links to", %{issue: issue} do
    {:ok, %User{id: user_id}} =
      Users.register_oauth_user(%{
        github_id: "gh_start_product_1",
        login: "start_product_user",
        email: "start_product_user@example.com"
      })

    {:ok, %Issue{id: issue_id} = issue} =
      issue |> Issue.changeset(%{owner_user_id: user_id}) |> Repo.update()

    expect(Tools, :start_os_process, fn %Run{} = run, _argv ->
      {:ok, %OsProcess{task_id: run.task_id, run: run, task: run.task}}
    end)

    assert {:ok, %OsProcess{task: %Task{issue_id: ^issue_id, stage: :product} = task}} =
             Pipeline.start_product_run(issue)

    # The owner lives on the issue; the task only links to it.
    assert %Issue{owner_user_id: ^user_id} = Repo.get!(Issue, task.issue_id)
  end

  test "keeps no task when the project has no product role", %{role: role, issue: issue} do
    {:ok, _deleted} = Roles.delete_role(system_scope(), role)

    assert {:error, :role_not_found} = Pipeline.start_product_run(issue)

    refute Repo.exists?(from t in Task, where: t.issue_id == ^issue.id)
  end

  test "keeps no task when the worktree cannot be created", %{project: project, issue: issue} do
    # The checkout stops being one after the project was saved.
    File.rm_rf!(Path.join(project.clone_path, ".git"))

    assert {:error, {:worktree_failed, _reason}} = Pipeline.start_product_run(issue)

    refute Repo.exists?(from t in Task, where: t.issue_id == ^issue.id)
    refute Repo.exists?(Run)
  end
end
