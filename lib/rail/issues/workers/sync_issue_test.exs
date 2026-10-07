defmodule Rail.Issues.Workers.SyncIssueTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Workers.SyncIssue
  alias Rail.Repo
  alias Rail.Users

  setup %{project: project} do
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

  test "editing a Duplicate issue leaves its Linear state alone", %{issue: issue} do
    issue = issue |> Issue.linear_changeset(%{state: :duplicate, state_name: "Duplicate"}) |> Repo.update!()
    {:ok, issue} = Issues.update_issue(issue, %{title: "Renamed"})

    # Pinned so a stateId in the input fails the match.
    title_only = %{"title" => "Renamed"}

    Req.Test.expect(Rail.Linear, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert %{"id" => "lin_sync_1", "input" => ^title_only} = Jason.decode!(body)["variables"]

      Req.Test.json(conn, %{"data" => %{"issueUpdate" => %{"success" => true}}})
    end)

    assert :ok = perform_job(SyncIssue, %{issue_id: issue.id, fields: ["title"]})
  end

  test "sends Linear the workflow state id and priority number, not Rail's words for them", %{issue: issue} do
    {:ok, issue} = Issues.update_issue(issue, %{state: :in_progress, priority: :urgent})

    Req.Test.expect(Rail.Linear, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert %{"id" => "lin_sync_1", "input" => %{"stateId" => "st_in_progress", "priority" => 1} = input} =
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

  test "a changed estimate goes in a mutation of its own after the rest", %{issue: issue} do
    {:ok, issue} = Issues.update_issue(issue, %{title: "New title", estimate: 3})
    test_pid = self()

    Req.Test.expect(Rail.Linear, 2, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:input, Jason.decode!(body)["variables"]["input"]})
      Req.Test.json(conn, %{"data" => %{"issueUpdate" => %{"success" => true}}})
    end)

    assert :ok = perform_job(SyncIssue, %{issue_id: issue.id, fields: ["title", "estimate"]})
    assert_received {:input, %{"title" => "New title"} = first}
    assert_received {:input, %{"estimate" => 3} = second}
    refute Map.has_key?(first, "estimate")
    refute Map.has_key?(second, "title")
  end

  test "the title still lands when Linear refuses the estimate", %{issue: issue} do
    {:ok, issue} = Issues.update_issue(issue, %{title: "New title", estimate: 7})
    test_pid = self()

    Req.Test.expect(Rail.Linear, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:landed, Jason.decode!(body)["variables"]["input"]})
      Req.Test.json(conn, %{"data" => %{"issueUpdate" => %{"success" => true}}})
    end)

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"issueUpdate" => %{"success" => false}}})
    end)

    assert {:error, {:linear_mutation_failed, "issueUpdate"}} =
             perform_job(SyncIssue, %{issue_id: issue.id, fields: ["title", "estimate"]})

    assert_received {:landed, %{"title" => "New title"}}
  end

  test "an estimate alone is one mutation", %{issue: issue} do
    {:ok, issue} = Issues.update_issue(issue, %{estimate: 2})

    Req.Test.expect(Rail.Linear, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert %{"input" => %{"estimate" => 2} = input} = Jason.decode!(body)["variables"]
      assert map_size(input) == 1
      Req.Test.json(conn, %{"data" => %{"issueUpdate" => %{"success" => true}}})
    end)

    assert :ok = perform_job(SyncIssue, %{issue_id: issue.id, fields: ["estimate"]})
  end
end
