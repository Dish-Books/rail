defmodule Rail.Issues.Actions.CaptureIssueTest do
  use Rail.DataCase, async: true

  import ExUnit.CaptureLog

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects.Schemas.LinearWorkspace
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Users.Schemas.User
  alias RailTest.Mocks.Linear, as: LinearMock

  test "capture_issue/3 creates issue using capturer's token" do
    %LinearWorkspace{id: ws_id} = Repo.insert!(LinearWorkspace.factory())

    project =
      Repo.insert!(%{
        Project.factory()
        | linear_workspace_id: ws_id,
          linear_team_id: "team_cap_1",
          linear_state_ids: %{"triage" => "st_triage_1"}
      })

    user =
      Repo.insert!(%{
        User.factory()
        | linear_access_token: "lin_usr_token_valid",
          linear_token_expires_at: DateTime.shift(DateTime.utc_now(), hour: 1)
      })

    scope = Scope.for_user(user)

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_captured_1",
      "identifier" => "ENG-301",
      "title" => "Short ask title",
      "description" => "Short ask title\nMore details here",
      "state" => %{"id" => "st_triage_1", "name" => "Triage", "type" => "triage"},
      "branchName" => "eng-301-branch",
      "url" => "https://linear.app/issue/ENG-301",
      "createdAt" => "2026-09-02T10:00:00.000Z",
      "updatedAt" => "2026-09-02T10:00:00.000Z"
    })

    assert {:ok,
            %Issue{
              id: "iss_" <> _id,
              external_id: "lin_captured_1",
              identifier: "ENG-301",
              title: "Short ask title",
              state: :triage,
              state_name: "Triage"
            }} = Issues.capture_issue(scope, project, "Short ask title\nMore details here")
  end

  test "capture_issue/3 falls back to workspace token and logs when user unlinked" do
    %LinearWorkspace{id: ws_id} = Repo.insert!(LinearWorkspace.factory())

    project =
      Repo.insert!(%{
        Project.factory()
        | linear_workspace_id: ws_id,
          linear_team_id: "team_cap_2",
          linear_state_ids: %{"triage" => "st_triage_2"}
      })

    user = Repo.insert!(%{User.factory() | linear_access_token: nil, linear_token_expires_at: nil})
    scope = Scope.for_user(user)

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_captured_2",
      "identifier" => "ENG-302",
      "title" => "Fallback ask title",
      "description" => "Fallback ask title",
      "state" => %{"id" => "st_triage_2", "name" => "Triage", "type" => "triage"},
      "branchName" => nil,
      "url" => "https://linear.app/issue/ENG-302",
      "createdAt" => nil,
      "updatedAt" => "not-a-datetime"
    })

    log =
      capture_log(fn ->
        assert {:ok, %Issue{external_id: "lin_captured_2"}} =
                 Issues.capture_issue(scope, project, "Fallback ask title")
      end)

    assert log =~ "[axis] pushed to Linear as the workspace"
  end

  test "capture_issue/3 returns error when Linear creation fails" do
    %LinearWorkspace{id: ws_id} = Repo.insert!(LinearWorkspace.factory())
    project = Repo.insert!(%{Project.factory() | linear_workspace_id: ws_id})

    LinearMock.mock_mutation_failure("issueCreate")

    scope = Scope.for_system()

    assert {:error, {:linear_mutation_failed, "issueCreate"}} =
             Issues.capture_issue(scope, project, "Failing ask")
  end

  test "capture_issue/3 returns :not_authorized for nil scope" do
    project = Repo.insert!(Project.factory())
    assert {:error, :not_authorized} = Issues.capture_issue(nil, project, "ask")
  end
end
