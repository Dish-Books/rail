defmodule Rail.Pipeline.Actions.CommitEngineerWorkTest do
  use Rail.DataCase, async: true

  alias Rail.Git
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
        name: "Commit Work Project",
        github_repo: "org/commit-work",
        github_installation_id: 47_011,
        linear_workspace: %{
          name: "Commit Work Workspace",
          external_id: "lin_ws_commit_work",
          token: "lin_api_token_commit_work",
          webhook_secret: "whsec_commit_work"
        },
        linear_team_key: "CMW",
        default_branch: "main",
        clone_path: "/tmp/repos/commit-work",
        linear_state_ids: %{"triage" => "st_triage"}
      })

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{
              "id" => "lin_commit_work_1",
              "identifier" => "CMW-1",
              "title" => "Invoice filters",
              "url" => "https://linear.app/rail/issue/CMW-1"
            }
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "Invoice filters"})
    {:ok, task} = Pipeline.create_task(issue, :engineer)
    repo = create_temp_git_repo()
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: repo})
    File.mkdir_p!(Path.join(task.scratch_path, "commits"))
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    stub(Git, :push_branch, fn _scope, _task -> :ok end)

    %{scope: scope, task: task, repo: repo, message_path: Path.join(task.scratch_path, "commits/CMW-1.md")}
  end

  test "commits what the engineer wrote, under the trailers naming the ticket and Rail", %{
    scope: scope,
    task: task,
    repo: repo,
    message_path: message_path
  } do
    File.write!(Path.join(repo, "feature.ex"), "one\n")
    File.write!(message_path, "CMW-1: add the vendor filter\n\nFilters invoices by vendor.\n")

    assert {:ok, sha} = Pipeline.commit_engineer_work(scope, task)
    assert byte_size(sha) == 40

    message = git!(repo, ["log", "-1", "--pretty=%B"])
    assert message =~ "CMW-1: add the vendor filter"
    assert message =~ "Filters invoices by vendor."
    assert message =~ "Ticket: CMW-1 https://linear.app/rail/issue/CMW-1"
    assert message =~ "Co-Authored-By: Rail <rail[bot]@railai.dev>"
  end

  # This is the Commit button: the human asked for it, so there is no written
  # message to use.
  test "falls back to a subject naming the ticket when nothing was written", %{
    scope: scope,
    task: task,
    repo: repo
  } do
    File.write!(Path.join(repo, "feature.ex"), "one\n")

    assert {:ok, _sha} = Pipeline.commit_engineer_work(scope, task)
    assert git!(repo, ["log", "-1", "--pretty=%s"]) =~ "CMW-1: follow-up changes"
  end

  # The file being gone is what makes its absence mean something next round.
  test "drops the message file once the commit exists", %{
    scope: scope,
    task: task,
    repo: repo,
    message_path: message_path
  } do
    File.write!(Path.join(repo, "feature.ex"), "one\n")
    File.write!(message_path, "CMW-1: add the vendor filter\n")

    assert {:ok, _sha} = Pipeline.commit_engineer_work(scope, task)
    refute File.exists?(message_path)
  end

  test "keeps the message file when the push failed", %{
    scope: scope,
    task: task,
    repo: repo,
    message_path: message_path
  } do
    File.write!(Path.join(repo, "feature.ex"), "one\n")
    File.write!(message_path, "CMW-1: add the vendor filter\n")

    stub(Git, :push_branch, fn _scope, _task -> {:error, "remote rejected"} end)

    assert {:error, "remote rejected"} = Pipeline.commit_engineer_work(scope, task)
    assert File.exists?(message_path)
  end

  test "refuses a worktree with nothing in it to commit", %{scope: scope, task: task} do
    assert {:error, :nothing_to_commit} = Pipeline.commit_engineer_work(scope, task)
  end
end
