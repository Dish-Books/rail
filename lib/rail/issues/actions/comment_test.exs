defmodule Rail.Issues.Actions.CommentTest do
  use Rail.DataCase, async: true

  alias Rail.GitHub.Client
  alias Rail.Issues
  alias Rail.Issues.Schemas.Comment
  alias Rail.Issues.Schemas.Issue
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Users

  setup %{project: project} do
    issue =
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: project.id,
        external_id: "lin_comm_1",
        identifier: "CMT-1",
        title: "Commentable Issue",
        state: :triage
      })
      |> Repo.insert!()

    %{issue: issue}
  end

  test "comment/3 posts as the scope's user and keeps the comment", %{issue: %{id: issue_id} = issue} do
    {:ok, %{id: user_id} = user} =
      Users.register_oauth_user(%{github_id: "gh_comment_owner", login: "comment_owner", email: "owner@example.com"})

    {:ok, user} =
      Users.update_user(Scope.for_system(), user, %{
        linear_access_token: "lin_owner_token",
        linear_refresh_token: "lin_owner_refresh",
        linear_token_expires_at: DateTime.shift(DateTime.utc_now(), hour: 1)
      })

    user |> Ecto.Changeset.change(linear_user_id: "lin_usr_owner") |> Repo.update!()

    Phoenix.PubSub.subscribe(Rail.PubSub, "issues")

    Req.Test.expect(Rail.Linear, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer lin_owner_token"]
      assert %{"input" => %{"issueId" => "lin_comm_1", "body" => "LGTM!"} = input} = Jason.decode!(body)["variables"]
      refute Map.has_key?(input, "parentId")

      Req.Test.json(conn, %{
        "data" => %{
          "commentCreate" => %{
            "success" => true,
            "comment" => %{
              "id" => "comment_999",
              "body" => "LGTM!",
              "createdAt" => "2026-09-13T10:00:00.000Z",
              "issue" => %{"id" => "lin_comm_1"},
              "user" => %{"id" => "lin_usr_owner", "name" => "Comment Owner"}
            }
          }
        }
      })
    end)

    assert {:ok,
            %Comment{
              issue_id: ^issue_id,
              parent_id: nil,
              external_id: "comment_999",
              body: "LGTM!",
              author_user_id: ^user_id,
              author_name: "Comment Owner"
            }} = Issues.comment(Scope.for_user(user), issue, %{body: "LGTM!"})

    assert_receive {:issue_comments_changed, ^issue_id}
  end

  test "comment/3 replies to a thread with the parent's Linear id", %{issue: issue} do
    %Comment{id: parent_id} =
      %Comment{}
      |> Comment.changeset(%{issue_id: issue.id, external_id: "lin_parent", body: "Open question"})
      |> Repo.insert!()

    Req.Test.expect(Rail.Linear, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert %{"input" => %{"parentId" => "lin_parent", "body" => "yes"}} = Jason.decode!(body)["variables"]

      Req.Test.json(conn, %{
        "data" => %{
          "commentCreate" => %{
            "success" => true,
            "comment" => %{
              "id" => "lin_reply",
              "body" => "yes",
              "issue" => %{"id" => "lin_comm_1"},
              "parent" => %{"id" => "lin_parent"}
            }
          }
        }
      })
    end)

    assert {:ok, %Comment{external_id: "lin_reply", parent_id: ^parent_id}} =
             Issues.comment(Scope.for_system(), issue, %{body: "yes", parent_id: parent_id})
  end

  test "comment/3 won't reply to a comment that isn't a thread on this issue", %{issue: issue} do
    # No Linear mock is queued, so a request would raise.
    assert {:error, :parent_not_found} =
             Issues.comment(Scope.for_system(), issue, %{body: "yes", parent_id: "com_missing"})
  end

  test "comment/3 posts as the workspace for the system", %{issue: issue} do
    Req.Test.expect(Rail.Linear, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer lin_api_test_seed"]

      Req.Test.json(conn, %{
        "data" => %{
          "commentCreate" => %{
            "success" => true,
            "comment" => %{"id" => "comment_sys", "body" => "From the pipeline", "issue" => %{"id" => "lin_comm_1"}}
          }
        }
      })
    end)

    assert {:ok, %Comment{external_id: "comment_sys", author_user_id: nil}} =
             Issues.comment(Scope.for_system(), issue, %{body: "From the pipeline"})
  end

  test "comment/3 returns an error when Linear does not create it", %{issue: issue} do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"commentCreate" => %{"success" => false}}})
    end)

    assert {:error, {:linear_mutation_failed, "commentCreate"}} =
             Issues.comment(Scope.for_system(), issue, %{body: "Failing comment"})

    Req.Test.expect(Rail.Linear, fn conn -> conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{}) end)

    assert {:error, {:linear_api_error, 500, _body}} =
             Issues.comment(Scope.for_system(), issue, %{body: "Unreachable comment"})

    assert [] = Repo.all(Comment)
  end

  describe "a GitHub issue" do
    test "comments as the App and keeps the comment, its author matched by GitHub id", %{github_project: project} do
      {:ok, %{id: author_id}} =
        Users.register_oauth_user(%{github_id: "9001", login: "octocat", email: "octo@example.com"})

      %Issue{id: issue_id} = issue = github_issue(project, %{number: 11})
      posted = github_comment_json(%{"body" => "On it"})

      Req.Test.expect(Client, 2, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        case {conn.method, conn.request_path} do
          {"POST", "/app/installations/1/access_tokens"} ->
            Req.Test.json(conn, %{"token" => "ghs_token"})

          {"POST", "/repos/example/test-gh/issues/11/comments"} ->
            assert %{"body" => "On it"} == Jason.decode!(body)
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(posted)
        end
      end)

      external_id = posted["node_id"]

      assert {:ok,
              %Comment{issue_id: ^issue_id, external_id: ^external_id, author_user_id: ^author_id, author_name: "octocat"}} =
               Issues.comment(system_scope(), issue, %{body: "On it"})
    end

    test "a reply goes up flat, quoting the comment it answers", %{github_project: project} do
      issue = github_issue(project, %{number: 12})

      parent =
        %Comment{}
        |> Comment.changeset(%{issue_id: issue.id, external_id: "IC_parent_#{issue.number}", body: "First line\nSecond"})
        |> Repo.insert!()

      Req.Test.expect(Client, 2, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        case conn.request_path do
          "/app/installations/1/access_tokens" ->
            Req.Test.json(conn, %{"token" => "ghs_token"})

          "/repos/example/test-gh/issues/12/comments" ->
            assert %{"body" => "> First line\n> Second\n\nAgreed"} == Jason.decode!(body)
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(github_comment_json(%{"user" => nil}))
        end
      end)

      assert {:ok, %Comment{parent_id: nil, author_user_id: nil}} =
               Issues.comment(system_scope(), issue, %{body: "Agreed", parent_id: parent.id})

      assert {:error, :parent_not_found} = Issues.comment(system_scope(), issue, %{body: "?", parent_id: "com_missing"})

      Req.Test.expect(Client, 2, fn conn ->
        case conn.request_path do
          "/app/installations/1/access_tokens" -> Req.Test.json(conn, %{"token" => "ghs_token"})
          "/repos/example/test-gh/issues/12/comments" -> Req.Test.transport_error(conn, :econnrefused)
        end
      end)

      assert {:error, %Req.TransportError{reason: :econnrefused}} = Issues.comment(system_scope(), issue, %{body: "Down"})
    end
  end
end
