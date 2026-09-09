defmodule Rail.Issues.Actions.CommentTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects.Schemas.LinearWorkspace
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Users.Schemas.User
  alias RailTest.Mocks.Linear, as: LinearMock

  test "comment/4 posts comment using owner user token" do
    %LinearWorkspace{id: ws_id} = Repo.insert!(LinearWorkspace.factory())
    project = Repo.insert!(%{Project.factory() | linear_workspace_id: ws_id})
    issue = Repo.insert!(%{Issue.factory() | project_id: project.id, external_id: "lin_comm_1"})

    owner =
      Repo.insert!(%{
        User.factory()
        | linear_access_token: "lin_owner_token",
          linear_token_expires_at: DateTime.shift(DateTime.utc_now(), hour: 1)
      })

    LinearMock.mock_create_comment_success(%{
      "id" => "comment_999",
      "body" => "Review complete. LGTM!",
      "createdAt" => "2026-09-05T12:00:00.000Z"
    })

    scope = Scope.for_system()

    assert {:ok, %{id: "comment_999", body: "Review complete. LGTM!"}} =
             Issues.comment(scope, issue, "Review complete. LGTM!", owner)
  end

  test "comment/4 works with user scope and default owner_user" do
    %LinearWorkspace{id: ws_id} = Repo.insert!(LinearWorkspace.factory())
    project = Repo.insert!(%{Project.factory() | linear_workspace_id: ws_id})
    issue = Repo.insert!(%{Issue.factory() | project_id: project.id, external_id: "lin_comm_user"})

    user =
      Repo.insert!(%{
        User.factory()
        | linear_access_token: "lin_user_token_3",
          linear_token_expires_at: DateTime.shift(DateTime.utc_now(), hour: 1)
      })

    LinearMock.mock_create_comment_success(%{
      "id" => "comment_user_1",
      "body" => "Comment from user scope",
      "createdAt" => "2026-09-05T12:00:00.000Z"
    })

    scope = Scope.for_user(user)

    assert {:ok, %{id: "comment_user_1"}} =
             Issues.comment(scope, issue, "Comment from user scope")
  end

  test "comment/4 returns error on Linear mutation failure" do
    %LinearWorkspace{id: ws_id} = Repo.insert!(LinearWorkspace.factory())
    project = Repo.insert!(%{Project.factory() | linear_workspace_id: ws_id})
    issue = Repo.insert!(%{Issue.factory() | project_id: project.id, external_id: "lin_comm_2"})

    LinearMock.mock_mutation_failure("commentCreate")
    scope = Scope.for_system()

    assert {:error, {:linear_mutation_failed, "commentCreate"}} =
             Issues.comment(scope, issue, "Failing comment")
  end

  test "comment/4 returns :not_authorized for nil scope" do
    issue = %Issue{project_id: "prj_1", external_id: "lin_1"}
    assert {:error, :not_authorized} = Issues.comment(nil, issue, "comment")
  end
end
