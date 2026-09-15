defmodule Rail.Pipeline.Actions.ReadCommitMessageTest do
  use Rail.DataCase, async: true

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
        name: "Read Commit Message Project",
        github_repo: "org/read-commit-message",
        github_installation_id: 47_010,
        linear_workspace: %{
          name: "Read Commit Message Workspace",
          external_id: "lin_ws_read_commit_message",
          token: "lin_api_token_read_commit_message",
          webhook_secret: "whsec_read_commit_message"
        },
        linear_team_key: "RCM",
        default_branch: "main",
        clone_path: "/tmp/repos/read-commit-message",
        linear_state_ids: %{"triage" => "st_triage"}
      })

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_read_commit_1", "identifier" => "RCM-1", "title" => "Read Commit Message"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "Read Commit Message"})
    {:ok, task} = Pipeline.create_task(issue, :engineer)
    commits_dir = Path.join(task.scratch_path, "commits")
    File.mkdir_p!(commits_dir)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    %{task: Repo.preload(task, :issue), message_path: Path.join(commits_dir, "RCM-1.md")}
  end

  test "reads the message the engineer wrote", %{task: task, message_path: path} do
    File.write!(path, "RCM-1: filter invoices by vendor\n\nAdds the vendor filter.\n")

    assert Pipeline.read_commit_message(task) =~ "RCM-1: filter invoices by vendor"
  end

  test "an unwritten message means the engineer is not finished", %{task: task} do
    assert Pipeline.read_commit_message(task) == nil
  end

  test "a blank file is no message: the agent opened it but did not write it", %{task: task, message_path: path} do
    File.write!(path, "   \n\n")

    assert Pipeline.read_commit_message(task) == nil
  end
end
