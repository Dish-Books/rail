defmodule Rail.Pipeline.Actions.AdoptPullRequestTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.GitHub.Client
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Round
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess

  setup %{project: %{linear_workspace_id: workspace_id}} do
    scope = system_scope()

    # The pull request's branch is on the remote alone, as one pushed from someone's own checkout is.
    remote = create_temp_git_repo(prefix: "rail_adopt_remote")
    git!(remote, ["checkout", "--quiet", "-b", "outside/vendor-filter"])
    File.write!(Path.join(remote, "filter.ex"), "vendor\n")
    git!(remote, ["add", "."])
    git!(remote, ["commit", "-m", "Add the vendor filter"])
    git!(remote, ["checkout", "--quiet", "main"])

    clone_path = create_temp_git_repo(initial_commit: false)
    git!(clone_path, ["remote", "add", "origin", remote])
    git!(clone_path, ["fetch", "--quiet", "origin", "main"])
    git!(clone_path, ["checkout", "--quiet", "-B", "main", "origin/main"])

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "lin_team_id"}]}}})
    end)

    {:ok, project} =
      Projects.create_project(scope, %{
        name: "Adopt Project",
        github_repo: "org/adopt",
        github_installation_id: 7003,
        key: "ADP",
        default_branch: "main",
        clone_path: clone_path,
        linear_state_ids: %{"in_review" => "st_in_review"},
        linear_workspace_id: workspace_id
      })

    for stage <- [:qa, :review, :review_lead] do
      {:ok, _role} =
        Roles.create_role(scope, project, %{
          cli: :claude,
          stage: stage,
          name: "#{stage} role",
          model: "claude-opus-5-5",
          system_prompt: "You are the #{stage} agent."
        })
    end

    issue =
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: project.id,
        external_id: "lin_adopt_1",
        identifier: "ADP-1",
        title: "Filter invoices by vendor",
        description: "Lets a person narrow the invoice list to one vendor.",
        branch_name: "outside/vendor-filter",
        state: :in_progress
      })
      |> Repo.insert!()

    pull_request = %{
      "number" => 12,
      "state" => "open",
      "draft" => false,
      "html_url" => "https://github.com/org/adopt/pull/12",
      "head" => %{"ref" => "outside/vendor-filter", "repo" => %{"full_name" => "org/adopt"}},
      "base" => %{"ref" => "main"}
    }

    Req.Test.stub(Client, fn conn ->
      case conn.request_path do
        "/app/installations/7003/access_tokens" -> Req.Test.json(conn, %{"token" => "ghs_token"})
        "/repos/org/adopt/pulls" -> Req.Test.json(conn, [pull_request])
      end
    end)

    # Every task's scratch directory is under its project's, and this project is the test's own.
    on_exit(fn -> File.rm_rf(Path.join(Application.fetch_env!(:rail, :scratch_root), project.id)) end)

    %{scope: scope, project: project, issue: issue, remote: remote, pull_request: pull_request}
  end

  test "starts the issue's task at Review on the pull request's branch, with QA and the code reviewer checking it", %{
    scope: scope,
    project: project,
    issue: issue,
    remote: remote
  } do
    expect(Tools, :start_os_process, 2, fn %Run{} = run, _argv -> {:ok, %OsProcess{run: run}} end)

    assert {:ok, %Task{} = task} = Pipeline.adopt_pull_request(scope, issue)

    worktree_path = Path.join(project.clone_path, ".worktrees/outside/vendor-filter")

    assert %Task{
             stage: :review,
             worktree_name: "outside/vendor-filter",
             worktree_path: ^worktree_path,
             pr_number: 12,
             pr_url: "https://github.com/org/adopt/pull/12",
             pr_is_draft: false,
             worktree_slot: slot
           } = Repo.reload!(task)

    assert is_integer(slot)
    assert git!(worktree_path, ["rev-parse", "HEAD"]) == git!(remote, ["rev-parse", "outside/vendor-filter"])
    refute Git.branch_unpushed?(worktree_path)

    # Nothing was planned, so the issue is the ticket and the round counts as approved.
    assert [
             %Round{
               number: 1,
               plan: nil,
               approved_at: %DateTime{},
               ticket: %Round.Ticket{
                 title: "Filter invoices by vendor",
                 description: "Lets a person narrow the invoice list to one vendor."
               }
             }
           ] = Pipeline.list_rounds(task)

    started = for %Run{status: :running} = run <- Repo.all(Run), run.task_id == task.id, do: Repo.preload(run, :role)
    assert started |> Enum.map(& &1.role.stage) |> Enum.sort() == [:qa, :review]
  end

  test "sets the worktree up once, and starts every check when the setup finishes", %{
    scope: scope,
    project: project,
    issue: issue
  } do
    {:ok, _project} = Projects.update_project(scope, project, %{worktree_setup_script: "scripts/setup.sh"})

    expect(Tools, :start_command_process, fn %Run{} = run, :setup, "./scripts/setup.sh", _opts ->
      {:ok, %OsProcess{kind: :setup, run: run}}
    end)

    assert {:ok, %Task{} = task} = Pipeline.adopt_pull_request(scope, issue)
    assert [%Run{status: :running} = setting_up] = Repo.all(from r in Run, where: r.task_id == ^task.id)

    setup =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: setting_up.id,
        task_id: task.id,
        kind: :setup,
        command: "./scripts/setup.sh",
        stream_path: "/tmp/#{setting_up.id}-setup.log",
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    # Two agents in all, both once the setup is done.
    expect(Tools, :start_os_process, 2, fn %Run{} = run, _argv -> {:ok, %OsProcess{run: run}} end)

    assert {:ok, %Run{status: :running}} = Pipeline.run_finished(setup, %{exit_code: 0})
    assert %Task{worktree_setup_at: %DateTime{}} = Repo.reload!(task)

    started = Repo.all(from r in Run, where: r.task_id == ^task.id and r.status == :running, preload: :role)
    assert started |> Enum.map(& &1.role.stage) |> Enum.sort() == [:qa, :review]
  end

  test "refuses a pull request Rail cannot take through Review, and leaves the issue without a task", %{
    scope: scope,
    issue: issue,
    pull_request: pull_request
  } do
    reject(Tools, :start_os_process, 2)

    for {changed, reason} <- [
          {%{"head" => %{"ref" => "outside/vendor-filter", "repo" => %{"full_name" => "someone/adopt"}}},
           :pull_request_from_fork},
          {%{"head" => %{"ref" => "outside/vendor-filter", "repo" => nil}}, :pull_request_from_fork},
          {%{"base" => %{"ref" => "release"}}, {:pull_request_base, "release"}}
        ] do
      Req.Test.stub(Client, fn conn ->
        case conn.request_path do
          "/app/installations/" <> _id -> Req.Test.json(conn, %{"token" => "ghs_token"})
          "/repos/org/adopt/pulls" -> Req.Test.json(conn, [Map.merge(pull_request, changed)])
        end
      end)

      assert {:error, ^reason} = Pipeline.adopt_pull_request(scope, issue)
    end

    Req.Test.stub(Client, fn conn ->
      case conn.request_path do
        "/app/installations/" <> _id -> Req.Test.json(conn, %{"token" => "ghs_token"})
        "/repos/org/adopt/pulls" -> Req.Test.json(conn, [])
      end
    end)

    assert {:error, :no_pull_request} = Pipeline.adopt_pull_request(scope, issue)
    refute Repo.get_by(Task, issue_id: issue.id)
  end

  test "refuses an issue that already has a task, a branch another task works on, and an issue the user cannot see", %{
    scope: scope,
    project: project,
    issue: issue
  } do
    stub(Tools, :start_os_process, fn %Run{} = run, _argv -> {:ok, %OsProcess{run: run}} end)

    assert {:error, :not_found} = Pipeline.adopt_pull_request(user_scope(project_ids: []), issue)

    assert {:ok, %Task{}} = Pipeline.adopt_pull_request(scope, issue)
    assert {:error, :task_exists} = Pipeline.adopt_pull_request(scope, issue)

    other =
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: project.id,
        external_id: "lin_adopt_2",
        identifier: "ADP-2",
        title: "The same branch",
        branch_name: "outside/vendor-filter",
        state: :todo
      })
      |> Repo.insert!()

    assert {:error, :pull_request_taken} = Pipeline.adopt_pull_request(scope, other)
  end

  test "leaves the issue without a task when the branch will not check out", %{scope: scope, issue: issue} do
    expect(Git, :get_or_create_worktree, fn _project, _task -> {:error, "no checkout"} end)

    assert {:error, "no checkout"} = Pipeline.adopt_pull_request(scope, issue)
    refute Repo.get_by(Task, issue_id: issue.id)
  end
end
