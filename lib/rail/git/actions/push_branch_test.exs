defmodule Rail.Git.Actions.PushBranchTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.GitHub.Client
  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Projects

  setup do
    scope = system_scope()

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "lin_team_id"}]}}})
    end)

    {:ok, project} =
      Projects.create_project(scope, %{
        name: "Push Branch Project",
        github_repo: "org/push-branch",
        github_installation_id: 47_021,
        linear_workspace: %{
          name: "Push Branch Workspace",
          external_id: "lin_ws_push_branch",
          token: "lin_api_token_push_branch",
          webhook_secret: "whsec_push_branch"
        },
        linear_team_key: "PSH",
        default_branch: "main",
        clone_path: "/tmp/repos/push-branch",
        linear_state_ids: %{"triage" => "st_triage"}
      })

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_psh_1", "identifier" => "PSH-1", "title" => "Push Branch"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "Push Branch"})
    {:ok, task} = Pipeline.create_task(issue, :engineer)

    # No initial commit on the remote: two repos with their own first commit have
    # unrelated histories, and the push is rejected rather than tested.
    remote = create_temp_git_repo(prefix: "rail_git_remote", initial_commit: false)
    git!(remote, ["config", "receive.denyCurrentBranch", "ignore"])

    repo = create_temp_git_repo()
    git!(repo, ["remote", "add", "origin", remote])

    {:ok, task} = Pipeline.update_task(task, %{worktree_path: repo, worktree_name: "main"})
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    %{scope: scope, project: project, task: task, repo: repo, remote: remote}
  end

  test "mints its own token and pushes the branch", %{scope: scope, task: task, repo: repo, remote: remote} do
    Req.Test.expect(Client, fn conn ->
      assert conn.request_path == "/app/installations/47021/access_tokens"
      Req.Test.json(conn, %{"token" => "ghs_installation_token"})
    end)

    File.write!(Path.join(repo, "feature.ex"), "one\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "feature"])

    assert :ok = Git.push_branch(scope, task)
    assert git!(repo, ["rev-parse", "HEAD"]) == git!(remote, ["rev-parse", "main"])
  end

  test "pushes past the repository's own pre-push hook", %{scope: scope, task: task, repo: repo, remote: remote} do
    Req.Test.expect(Client, fn conn -> Req.Test.json(conn, %{"token" => "ghs_installation_token"}) end)

    hook = Path.join([repo, ".git", "hooks", "pre-push"])
    File.write!(hook, "#!/bin/sh\necho 'local CI failed'\nexit 1\n")
    File.chmod!(hook, 0o755)

    File.write!(Path.join(repo, "feature.ex"), "one\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "feature"])

    assert :ok = Git.push_branch(scope, task)
    assert git!(repo, ["rev-parse", "HEAD"]) == git!(remote, ["rev-parse", "main"])
  end

  test "reports what git said when the push fails", %{scope: scope, task: task, repo: repo} do
    Req.Test.expect(Client, fn conn -> Req.Test.json(conn, %{"token" => "ghs_installation_token"}) end)

    git!(repo, ["remote", "set-url", "origin", "/tmp/nowhere_#{System.unique_integer([:positive])}"])

    assert {:error, output} = Git.push_branch(scope, task)
    assert output =~ "does not appear to be a git repository"
  end

  test "says so when GitHub will not mint a token", %{scope: scope, task: task} do
    Req.Test.expect(Client, fn conn ->
      conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "Not Found"})
    end)

    assert {:error, {:github_api_error, 404, _body}} = Git.push_branch(scope, task)
  end
end
