defmodule Rail.Issues.Workers.SyncIssueTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Issues
  alias Rail.Issues.Workers.SyncIssue
  alias Rail.Projects
  alias Rail.Repo

  setup do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "lin_team_id"}]}}})
    end)

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Sync Issue Project",
        github_repo: "org/sync-issue",
        github_installation_id: 5902,
        linear_workspace: %{
          name: "Sync Issue Workspace",
          external_id: "lin_ws_sync_issue",
          token: "lin_api_token_sync_issue",
          webhook_secret: "whsec_sync_issue"
        },
        linear_team_key: "SYN",
        default_branch: "main",
        clone_path: "/tmp/repos/sync-issue",
        linear_state_ids: %{"triage" => "st_triage", "in_progress" => "st_prog"}
      })

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{
              "id" => "lin_sync_1",
              "identifier" => "SYN-1",
              "title" => "Sync Issue",
              "state" => %{"id" => "st_triage", "name" => "Triage", "type" => "triage"}
            }
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(project, %{description: "Sync Issue"})

    %{project: project, issue: issue}
  end

  test "pushes only the fields the update changed", %{issue: issue} do
    {:ok, issue} = Issues.update_issue(issue, %{title: "New title", description: "New body"})

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueUpdate" => %{
            "success" => true,
            "issue" => %{
              "id" => "lin_sync_1",
              "identifier" => "SYN-1",
              "title" => "New title"
            }
          }
        }
      })
    end)

    assert :ok = perform_job(SyncIssue, %{issue_id: issue.id, fields: ["title"]})
  end

  test "sends Linear the workflow state id and priority number, not Rail's words for them", %{issue: issue} do
    {:ok, issue} = Issues.update_issue(issue, %{state: :in_progress, priority: :urgent})

    Req.Test.expect(Rail.Linear, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert %{"id" => "lin_sync_1", "input" => %{"stateId" => "st_prog", "priority" => 1} = input} =
               Jason.decode!(body)["variables"]

      assert map_size(input) == 2

      Req.Test.json(conn, %{"data" => %{"issueUpdate" => %{"success" => true}}})
    end)

    assert :ok = perform_job(SyncIssue, %{issue_id: issue.id, fields: ["state", "priority"]})
  end

  test "fails the job when Linear does not take the update", %{issue: issue} do
    {:ok, issue} = Issues.update_issue(issue, %{title: "Refused"})

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"issueUpdate" => %{"success" => false}}})
    end)

    assert {:error, {:linear_mutation_failed, "issueUpdate"}} =
             perform_job(SyncIssue, %{issue_id: issue.id, fields: ["title"]})
  end

  test "says nothing to Linear when no pushable field changed", %{issue: issue} do
    # No Linear mock is queued, so a request would raise.
    assert :ok = perform_job(SyncIssue, %{issue_id: issue.id, fields: ["url", "identifier"]})
  end

  test "an issue that is gone needs no sync", %{issue: issue} do
    Repo.delete!(issue)

    assert :ok = perform_job(SyncIssue, %{issue_id: issue.id, fields: ["title"]})
  end
end
