defmodule Rail.Issues.Workers.SyncIssueTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Issues
  alias Rail.Issues.Workers.SyncIssue
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Users

  setup do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "teams" => %{
            "nodes" => [
              %{
                "id" => "lin_team_id",
                "states" => %{
                  "nodes" => [
                    %{"id" => "st_triage", "type" => "triage", "position" => 0},
                    %{"id" => "st_prog", "type" => "started", "position" => 1}
                  ]
                }
              }
            ]
          }
        }
      })
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
        clone_path: "/tmp/repos/sync-issue"
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

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Sync Issue"})

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

  test "sends Linear the assignee's Linear user id, and null when unassigned", %{issue: issue} do
    {:ok, user} =
      Users.register_oauth_user(%{github_id: "gh_sync_assign", login: "sync_assign", email: "sync_assign@example.com"})

    user |> Ecto.Changeset.change(linear_user_id: "lin_usr_assign") |> Repo.update!()

    {:ok, issue} = Issues.update_issue(issue, %{owner_user_id: user.id})

    Req.Test.expect(Rail.Linear, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert %{"input" => %{"assigneeId" => "lin_usr_assign"}} = Jason.decode!(body)["variables"]
      Req.Test.json(conn, %{"data" => %{"issueUpdate" => %{"success" => true}}})
    end)

    assert :ok = perform_job(SyncIssue, %{issue_id: issue.id, fields: ["owner_user_id"]})

    {:ok, issue} = Issues.update_issue(issue, %{owner_user_id: nil})

    Req.Test.expect(Rail.Linear, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert %{"input" => %{"assigneeId" => nil}} = Jason.decode!(body)["variables"]
      Req.Test.json(conn, %{"data" => %{"issueUpdate" => %{"success" => true}}})
    end)

    assert :ok = perform_job(SyncIssue, %{issue_id: issue.id, fields: ["owner_user_id"]})
  end

  test "fails the job when Linear does not take the update", %{issue: issue} do
    {:ok, issue} = Issues.update_issue(issue, %{title: "Refused"})

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"issueUpdate" => %{"success" => false}}})
    end)

    assert {:error, {:linear_mutation_failed, "issueUpdate"}} =
             perform_job(SyncIssue, %{issue_id: issue.id, fields: ["title"]})
  end

  test "fails the job with Linear's error when the request does not go through", %{issue: issue} do
    {:ok, issue} = Issues.update_issue(issue, %{title: "Unreachable"})

    Req.Test.expect(Rail.Linear, fn conn ->
      conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => "bad request"})
    end)

    assert {:error, {:linear_api_error, 400, %{"error" => "bad request"}}} =
             perform_job(SyncIssue, %{issue_id: issue.id, fields: ["title"]})
  end

  test "says nothing to Linear when no pushable field changed", %{issue: issue} do
    # No Linear mock is queued, so a request would raise.
    assert :ok =
             perform_job(SyncIssue, %{issue_id: issue.id, fields: ["url", "identifier", "not_a_field_rail_knows_xyz"]})
  end

  test "an issue that is gone needs no sync", %{issue: issue} do
    Repo.delete!(issue)

    assert :ok = perform_job(SyncIssue, %{issue_id: issue.id, fields: ["title"]})
  end
end
