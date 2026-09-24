defmodule Rail.Issues.Actions.ClaimIssueTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Workers.SyncIssue
  alias Rail.Scope
  alias Rail.Users

  setup %{project: project} do
    issue =
      %Issue{}
      |> Issue.linear_changeset(%{
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
          Users.register_oauth_user(%{github_id: "gh_#{login}", login: login, email: "#{login}@example.com"})

        user |> Ecto.Changeset.change(linear_user_id: "lin_usr_#{login}") |> Repo.update!()
      end)

    %{issue: issue, claimer: claimer, rival: rival}
  end

  test "makes the user the owner and tells Linear", %{issue: issue, claimer: %{id: claimer_id} = claimer} do
    assert {:ok, %Issue{owner_user_id: ^claimer_id}} = Issues.claim_issue(Scope.for_user(claimer), issue)
    assert_enqueued(worker: SyncIssue, args: %{issue_id: issue.id, fields: ["owner_user_id"]})
  end

  test "refuses an issue somebody claimed since it was read", %{issue: issue, claimer: claimer, rival: rival} do
    {:ok, _claimed} = Issues.claim_issue(Scope.for_user(rival), issue)

    assert {:error, :already_assigned} = Issues.claim_issue(Scope.for_user(claimer), issue)
    assert Repo.get!(Issue, issue.id).owner_user_id == rival.id
  end

  test "refuses a user who never linked Linear", %{issue: issue} do
    {:ok, unlinked} =
      Users.register_oauth_user(%{github_id: "gh_unlinked", login: "unlinked", email: "unlinked@example.com"})

    assert {:error, :linear_not_linked} = Issues.claim_issue(Scope.for_user(unlinked), issue)
    assert Repo.get!(Issue, issue.id).owner_user_id == nil
  end
end
