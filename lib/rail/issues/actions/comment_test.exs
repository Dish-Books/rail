defmodule Rail.Issues.Actions.CommentTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Users

  setup do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Comment Project",
        github_repo: "org/comment",
        github_installation_id: 5401,
        linear_workspace: %{
          name: "Comment Workspace",
          external_id: "lin_ws_comment",
          token: "lin_api_token_comment",
          webhook_secret: "whsec_comment"
        },
        linear_team_id: "team_comment",
        linear_team_key: "CMT",
        default_branch: "main",
        clone_path: "/tmp/repos/comment"
      })

    issue =
      %Issue{}
      |> Issue.changeset(%{
        project_id: project.id,
        external_id: "lin_comm_1",
        identifier: "CMT-1",
        title: "Commentable Issue",
        state: :triage
      })
      |> Repo.insert!()

    %{issue: issue}
  end

  test "comment/3 posts as the scope's user", %{issue: issue} do
    {:ok, user} =
      Users.register_oauth_user(%{github_id: "gh_comment_owner", login: "comment_owner", email: "owner@example.com"})

    {:ok, user} =
      Users.update_user(Scope.for_system(), user, %{
        linear_access_token: "lin_owner_token",
        linear_refresh_token: "lin_owner_refresh",
        linear_token_expires_at: DateTime.shift(DateTime.utc_now(), hour: 1)
      })

    Req.Test.expect(Rail.Linear, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer lin_owner_token"]
      assert %{"input" => %{"issueId" => "lin_comm_1", "body" => "LGTM!"}} = Jason.decode!(body)["variables"]

      Req.Test.json(conn, %{
        "data" => %{"commentCreate" => %{"success" => true, "comment" => %{"id" => "comment_999", "body" => "LGTM!"}}}
      })
    end)

    assert {:ok, %{"id" => "comment_999", "body" => "LGTM!"}} =
             Issues.comment(Scope.for_user(user), issue, "LGTM!")
  end

  test "comment/3 posts as the workspace for the system", %{issue: issue} do
    Req.Test.expect(Rail.Linear, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer lin_api_token_comment"]

      Req.Test.json(conn, %{
        "data" => %{"commentCreate" => %{"success" => true, "comment" => %{"id" => "comment_sys"}}}
      })
    end)

    assert {:ok, %{"id" => "comment_sys"}} = Issues.comment(Scope.for_system(), issue, "From the pipeline")
  end

  test "comment/3 returns an error when Linear does not create it", %{issue: issue} do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"commentCreate" => %{"success" => false}}})
    end)

    assert {:error, {:linear_mutation_failed, "commentCreate"}} =
             Issues.comment(Scope.for_system(), issue, "Failing comment")
  end
end
