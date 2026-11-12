defmodule Rail.Issues.Actions.ClaimIssueTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Workers.AdvanceTrackerState
  alias Rail.Issues.Workers.SyncIssue
  alias Rail.Projects
  alias Rail.Scope
  alias Rail.Users

  setup %{project: project} do
    issue =
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: project.id,
        external_id: "lin_claim",
        identifier: "CLM-1",
        title: "Up for grabs",
        state: :todo
      })
      |> Repo.insert!()

    [claimer, rival] =
      Enum.map(["claimer", "rival"], fn login ->
        {:ok, user} =
          Users.register_oauth_user(%{
            github_id: "gh_#{login}_claim-issue",
            login: "#{login}-claim-issue",
            email: "#{login}-claim-issue@example.com"
          })

        user |> Ecto.Changeset.change(linear_user_id: "lin_usr_#{login}") |> Repo.update!()
      end)

    %{issue: issue, claimer: claimer, rival: rival}
  end

  test "makes the user the owner and tells Linear", %{issue: issue, claimer: %{id: claimer_id} = claimer} do
    assert {:ok, %Issue{owner_user_id: ^claimer_id}} = Issues.claim_issue(Scope.for_user(claimer), issue)
    assert_enqueued(worker: SyncIssue, args: %{issue_id: issue.id, fields: ["owner_user_id"]})
  end

  test "queues the move that catches the ticket's Linear status up", %{issue: issue, claimer: claimer} do
    {:ok, _claimed} = Issues.claim_issue(Scope.for_user(claimer), issue)

    assert_enqueued(worker: AdvanceTrackerState, args: %{issue_id: issue.id})
  end

  test "refuses an issue somebody claimed since it was read", %{issue: issue, claimer: claimer, rival: rival} do
    {:ok, _claimed} = Issues.claim_issue(Scope.for_user(rival), issue)

    assert {:error, :already_assigned} = Issues.claim_issue(Scope.for_user(claimer), issue)
    assert Repo.get!(Issue, issue.id).owner_user_id == rival.id
  end

  test "refuses a user who never linked Linear", %{issue: issue} do
    {:ok, unlinked} =
      Users.register_oauth_user(%{
        github_id: "gh_unlinked",
        login: "unlinked-claim-issue",
        email: "unlinked-claim-issue@example.com"
      })

    assert {:error, :linear_not_linked} = Issues.claim_issue(Scope.for_user(unlinked), issue)
    assert Repo.get!(Issue, issue.id).owner_user_id == nil
  end

  test "a GitHub issue is claimable without a Linear account, and catches its label up", %{github_project: project} do
    {:ok, %{id: user_id} = user} =
      Users.register_oauth_user(%{github_id: "gh_gh_claimer", login: "gh-claimer", email: "gh-claimer@example.com"})

    issue = github_issue(project)

    assert {:ok, %Issue{owner_user_id: ^user_id}} = Issues.claim_issue(Scope.for_user(user), issue)
    assert_enqueued(worker: AdvanceTrackerState, args: %{issue_id: issue.id})
  end

  test "someone without GitHub cannot own a GitHub issue, and nothing is sent to GitHub", %{github_project: project} do
    {:ok, user} =
      Users.register_oauth_user(%{github_id: "gh_tester_claim", login: "tester-claim", email: "tester-claim@example.com"})

    {:ok, user} = Users.unlink_github(Scope.for_user(user))
    issue = github_issue(project)

    assert {:error, :github_not_linked} = Issues.claim_issue(Scope.for_user(user), issue)
    assert %Issue{owner_user_id: nil} = Repo.reload!(issue)
    refute_enqueued(worker: AdvanceTrackerState, args: %{issue_id: issue.id})
  end

  test "a user the issue's tracker cannot take as owner is told why, and nothing changes", %{github_project: project} do
    {:ok, user} = Users.register_oauth_user(%{github_id: "gh_refused", login: "refused", email: "refused@example.com"})
    issue = github_issue(project)
    expect(Rail.Issues.Tracker.Github, :check_assignable, fn %{id: _user_id} -> {:error, :not_on_github} end)

    assert {:error, :not_on_github} = Issues.claim_issue(Scope.for_user(user), issue)
    assert %Issue{owner_user_id: nil} = Repo.reload!(issue)
  end

  test "anyone can claim a Rail-tracked issue, Linear or not, and the change is queued for open pages" do
    key = "Clm#{System.unique_integer([:positive])}"

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Rail-tracked",
        github_repo: "example/#{key}",
        github_installation_id: 1,
        tracker: :local,
        key: key,
        default_branch: "main",
        clone_path: "/tmp/#{key}"
      })

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{title: "Up for grabs"})

    {:ok, %{id: user_id} = user} =
      Users.register_oauth_user(%{github_id: "gh_local_claimer", login: "local-claimer", email: "lcl@example.com"})

    assert {:ok, %Issue{owner_user_id: ^user_id}} = Issues.claim_issue(Scope.for_user(user), issue)
    assert_enqueued(worker: SyncIssue, args: %{issue_id: issue.id, fields: ["owner_user_id"]})
  end
end
