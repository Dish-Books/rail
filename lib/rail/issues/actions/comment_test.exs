defmodule Rail.Issues.Actions.CommentTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Projects
  alias Rail.Scope
  alias Rail.Users
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    scope = system_scope()

    {:ok, project} =
      Projects.create_project(scope, %{
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

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_comm_1",
      "identifier" => "ENG-801",
      "title" => "Commentable Issue",
      "description" => "Commentable Issue",
      "state" => %{"id" => "st_triage", "name" => "Triage", "type" => "triage"},
      "branchName" => "eng-801-comment",
      "url" => "https://linear.app/issue/ENG-801",
      "createdAt" => "2026-09-01T10:00:00.000Z",
      "updatedAt" => "2026-09-01T10:00:00.000Z"
    })

    {:ok, issue} = Issues.create_issue(project, %{description: "Commentable Issue"})

    %{project: project, issue: issue}
  end

  test "comment/4 posts comment using owner user token", %{issue: issue} do
    {:ok, owner} =
      Users.register_oauth_user(%{
        github_id: "gh_comment_owner",
        login: "comment_owner",
        email: "comment_owner@example.com"
      })

    {:ok, owner} =
      Users.update_user(Scope.for_system(), owner, %{
        linear_access_token: "lin_owner_token",
        linear_refresh_token: "lin_owner_refresh",
        linear_token_expires_at: DateTime.shift(DateTime.utc_now(), hour: 1)
      })

    LinearMock.mock_create_comment_success(%{
      "id" => "comment_999",
      "body" => "Review complete. LGTM!",
      "createdAt" => "2026-09-05T12:00:00.000Z"
    })

    assert {:ok, %{id: "comment_999", body: "Review complete. LGTM!"}} =
             Issues.comment(issue, "Review complete. LGTM!", owner)
  end

  test "comment/4 works with user scope and default owner_user", %{issue: issue} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_comment_user",
        login: "comment_user",
        email: "comment_user@example.com"
      })

    Users.update_user(Scope.for_system(), user, %{
      linear_access_token: "lin_user_token_3",
      linear_refresh_token: "lin_user_refresh_3",
      linear_token_expires_at: DateTime.shift(DateTime.utc_now(), hour: 1)
    })

    LinearMock.mock_create_comment_success(%{
      "id" => "comment_user_1",
      "body" => "Comment from user scope",
      "createdAt" => "2026-09-05T12:00:00.000Z"
    })

    assert {:ok, %{id: "comment_user_1"}} =
             Issues.comment(issue, "Comment from user scope")
  end

  test "comment/4 returns error on Linear mutation failure", %{issue: issue} do
    LinearMock.mock_mutation_failure("commentCreate")

    assert {:error, {:linear_mutation_failed, "commentCreate"}} =
             Issues.comment(issue, "Failing comment")
  end
end
