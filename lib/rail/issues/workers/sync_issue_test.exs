defmodule Rail.Issues.Workers.SyncIssueTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.GitHub.Client
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
    issue = issue |> Issue.tracker_changeset(%{state: :duplicate, state_name: "Duplicate"}) |> Repo.update!()
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

  describe "a GitHub issue" do
    setup %{github_project: project} do
      %{github: github_issue(project, %{number: 7, state: :triage, title: "Before"})}
    end

    test "sends only the title and body that changed, never its labels or assignees", %{github: issue} do
      {:ok, issue} = Issues.update_issue(issue, %{title: "After", description: "Body"})

      Req.Test.expect(Client, 2, fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", "/app/installations/1/access_tokens"} ->
            Req.Test.json(conn, %{"token" => "ghs_token"})

          {"PATCH", "/repos/example/test-gh/issues/7"} ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            assert %{"title" => "After", "body" => "Body"} == Jason.decode!(body)
            Req.Test.json(conn, github_issue_json(%{"number" => 7}))
        end
      end)

      assert :ok = perform_job(SyncIssue, %{issue_id: issue.id, fields: ["title", "description"]})
    end

    test "moves its status label, taking off the old one and reopening it if closed", %{github: issue} do
      {:ok, issue} = Issues.update_issue(issue, %{state: :todo})

      live =
        github_issue_json(%{
          "number" => 7,
          "state" => "closed",
          "labels" => [%{"name" => "rail:triage"}, %{"name" => "bug"}]
        })

      Req.Test.expect(Client, 5, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        case {conn.method, conn.request_path} do
          {"POST", "/app/installations/1/access_tokens"} ->
            Req.Test.json(conn, %{"token" => "ghs_token"})

          {"GET", "/repos/example/test-gh/issues/7"} ->
            Req.Test.json(conn, live)

          {"PATCH", "/repos/example/test-gh/issues/7"} ->
            assert %{"state" => "open", "state_reason" => "reopened"} == Jason.decode!(body)
            Req.Test.json(conn, live)

          {"POST", "/repos/example/test-gh/issues/7/labels"} ->
            assert %{"labels" => ["rail:todo"]} == Jason.decode!(body)
            Req.Test.json(conn, [])

          {"DELETE", "/repos/example/test-gh/issues/7/labels/rail%3Atriage"} ->
            Req.Test.json(conn, [])
        end
      end)

      assert :ok = perform_job(SyncIssue, %{issue_id: issue.id, fields: ["state"]})
    end

    test "closes it with the reason that matches, leaving its labels", %{github: issue} do
      for {state, reason} <- [done: "completed", canceled: "not_planned", duplicate: "duplicate"] do
        {:ok, issue} = Issues.update_issue(issue, %{state: state})

        Req.Test.expect(Client, 3, fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)

          case {conn.method, conn.request_path} do
            {"POST", "/app/installations/1/access_tokens"} ->
              Req.Test.json(conn, %{"token" => "ghs_token"})

            {"GET", "/repos/example/test-gh/issues/7"} ->
              Req.Test.json(conn, github_issue_json(%{"number" => 7}))

            {"PATCH", "/repos/example/test-gh/issues/7"} ->
              assert %{"state" => "closed", "state_reason" => ^reason} = Jason.decode!(body)
              Req.Test.json(conn, github_issue_json(%{"number" => 7}))
          end
        end)

        assert :ok = perform_job(SyncIssue, %{issue_id: issue.id, fields: ["state"]})
      end
    end

    test "swaps its priority label", %{github: issue} do
      {:ok, issue} = Issues.update_issue(issue, %{priority: :urgent})
      live = github_issue_json(%{"number" => 7, "labels" => [%{"name" => "rail:medium"}]})

      Req.Test.expect(Client, 4, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        case {conn.method, conn.request_path} do
          {"POST", "/app/installations/1/access_tokens"} ->
            Req.Test.json(conn, %{"token" => "ghs_token"})

          {"GET", "/repos/example/test-gh/issues/7"} ->
            Req.Test.json(conn, live)

          {"POST", "/repos/example/test-gh/issues/7/labels"} ->
            assert %{"labels" => ["rail:urgent"]} == Jason.decode!(body)
            Req.Test.json(conn, [])

          {"DELETE", "/repos/example/test-gh/issues/7/labels/rail%3Amedium"} ->
            conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{})
        end
      end)

      assert :ok = perform_job(SyncIssue, %{issue_id: issue.id, fields: ["priority"]})
    end

    test "unassigns only the owner Rail had and assigns the new one", %{github: issue} do
      [before, later] =
        Enum.map(["gh-before", "gh-later"], fn login ->
          {:ok, user} =
            Users.register_oauth_user(%{github_id: "gh_#{login}", login: login, email: "#{login}@example.com"})

          user
        end)

      {:ok, issue} = Issues.update_issue(issue, %{owner_user_id: before.id})
      {:ok, issue} = Issues.update_issue(issue, %{owner_user_id: later.id})

      Req.Test.expect(Client, 3, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        case {conn.method, conn.request_path} do
          {"POST", "/app/installations/1/access_tokens"} ->
            Req.Test.json(conn, %{"token" => "ghs_token"})

          {"DELETE", "/repos/example/test-gh/issues/7/assignees"} ->
            assert %{"assignees" => ["gh-before"]} == Jason.decode!(body)
            Req.Test.json(conn, %{})

          {"POST", "/repos/example/test-gh/issues/7/assignees"} ->
            assert %{"assignees" => ["gh-later"]} == Jason.decode!(body)
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{})
        end
      end)

      assert :ok =
               perform_job(SyncIssue, %{issue_id: issue.id, fields: ["owner_user_id"], previous_owner_user_id: before.id})

      {:ok, issue} = Issues.update_issue(issue, %{owner_user_id: nil})

      Req.Test.expect(Client, 2, fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", "/app/installations/1/access_tokens"} -> Req.Test.json(conn, %{"token" => "ghs_token"})
          {"DELETE", "/repos/example/test-gh/issues/7/assignees"} -> Req.Test.json(conn, %{})
        end
      end)

      assert :ok =
               perform_job(SyncIssue, %{issue_id: issue.id, fields: ["owner_user_id"], previous_owner_user_id: later.id})
    end

    test "an open issue moving between open states only has its labels moved", %{github: issue} do
      {:ok, issue} = Issues.update_issue(issue, %{state: :in_progress})
      live = github_issue_json(%{"number" => 7, "labels" => [%{"name" => "rail:triage"}]})

      Req.Test.expect(Client, 4, fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", "/app/installations/1/access_tokens"} ->
            Req.Test.json(conn, %{"token" => "ghs_token"})

          {"GET", "/repos/example/test-gh/issues/7"} ->
            Req.Test.json(conn, live)

          {"POST", "/repos/example/test-gh/issues/7/labels"} ->
            Req.Test.json(conn, [])

          {"DELETE", "/repos/example/test-gh/issues/7/labels/rail%3Atriage"} ->
            conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
        end
      end)

      assert {:error, {:github_api_error, 500, _body}} = perform_job(SyncIssue, %{issue_id: issue.id, fields: ["state"]})
    end

    test "fails the job with GitHub's error, for Oban to retry", %{github: issue} do
      {:ok, issue} = Issues.update_issue(issue, %{state: :todo})

      Req.Test.expect(Client, 2, fn conn ->
        case conn.request_path do
          "/app/installations/1/access_tokens" -> Req.Test.json(conn, %{"token" => "ghs_token"})
          "/repos/example/test-gh/issues/7" -> conn |> Plug.Conn.put_status(410) |> Req.Test.json(%{})
        end
      end)

      assert {:error, :github_issues_disabled} = perform_job(SyncIssue, %{issue_id: issue.id, fields: ["state"]})
    end
  end
end
