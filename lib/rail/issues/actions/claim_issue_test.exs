defmodule Rail.Issues.Actions.ClaimIssueTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Workers.SyncIssue
  alias Rail.Projects
  alias Rail.Scope
  alias Rail.Users
  alias Rail.Users.Schemas.User

  setup do
    key = "Clm#{System.unique_integer([:positive])}"

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Claimed",
        github_repo: "example/#{key}",
        github_installation_id: 1,
        key: key,
        default_branch: "main",
        clone_path: "/tmp/#{key}"
      })

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{title: "Up for grabs"})

    [claimer, rival] =
      Enum.map(["claimer", "rival"], fn login ->
        {:ok, user} =
          Users.register_oauth_user(%{
            github_id: "gh_#{login}_claim-issue",
            login: "#{login}-claim-issue",
            email: "#{login}-claim-issue@example.com"
          })

        user
      end)

    %{issue: issue, claimer: claimer, rival: rival}
  end

  test "makes anyone with GitHub the owner, and the change is queued for open pages", %{
    issue: issue,
    claimer: %{id: claimer_id} = claimer
  } do
    assert {:ok, %Issue{owner_user_id: ^claimer_id}} = Issues.claim_issue(Scope.for_user(claimer), issue)
    assert_enqueued(worker: SyncIssue, args: %{issue_id: issue.id})
  end

  test "refuses an issue somebody claimed since it was read", %{issue: issue, claimer: claimer, rival: rival} do
    {:ok, _claimed} = Issues.claim_issue(Scope.for_user(rival), issue)

    assert {:error, :already_assigned} = Issues.claim_issue(Scope.for_user(claimer), issue)
    assert Repo.get!(Issue, issue.id).owner_user_id == rival.id
  end

  test "someone who disconnected GitHub cannot claim an issue, even from a scope built before",
       %{issue: %Issue{id: issue_id} = issue, claimer: claimer} do
    scope = Scope.for_user(claimer)
    {:ok, _claimer} = Users.unlink_github(scope)

    assert {:error, :github_not_linked} = Issues.claim_issue(scope, issue)
    assert %Issue{owner_user_id: nil} = Repo.get!(Issue, issue_id)
    refute_enqueued(worker: SyncIssue, args: %{issue_id: issue_id})
  end

  test "a user who is gone claims nothing", %{issue: %Issue{id: issue_id} = issue} do
    assert {:error, :not_found} = Issues.claim_issue(Scope.for_user(%User{id: "usr_gone", github_id: "gh_gone"}), issue)
    assert %Issue{owner_user_id: nil} = Repo.get!(Issue, issue_id)
  end
end
