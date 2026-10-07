defmodule Rail.Issues.Actions.UpdateIssueTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Workers.AdvanceTrackerState
  alias Rail.Issues.Workers.SyncIssue
  alias Rail.Users

  setup %{project: project} do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{
              "id" => "lin_up_1",
              "identifier" => "ENG-601",
              "title" => "Initial Title",
              "description" => "Initial Title",
              "state" => %{"id" => "st_triage", "name" => "Triage", "type" => "triage"},
              "url" => "https://linear.app/issue/ENG-601",
              "createdAt" => "2026-09-01T10:00:00.000Z",
              "updatedAt" => "2026-09-01T10:00:00.000Z"
            }
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Initial Title"})

    %{project: project, issue: issue}
  end

  test "writes the row and says nothing to Linear itself", %{issue: issue} do
    # No Linear mock is queued: a push from here would raise on the request.
    assert {:ok, %Issue{title: "Updated Title", description: "Updated body"}} =
             Issues.update_issue(issue, %{title: "Updated Title", description: "Updated body"})

    assert %Issue{title: "Updated Title"} = Repo.get!(Issue, issue.id)
  end

  test "enqueues the sync with exactly the fields that changed", %{issue: issue} do
    {:ok, _issue} = Issues.update_issue(issue, %{title: "Only the title"})

    assert_enqueued(worker: SyncIssue, args: %{issue_id: issue.id, fields: ["title"]})
  end

  test "enqueues nothing when nothing changed", %{issue: issue} do
    {:ok, _issue} = Issues.update_issue(issue, %{title: issue.title})

    refute_enqueued(worker: SyncIssue)
  end

  test "giving an unowned issue an owner queues the move that catches its Linear status up, and only then", %{
    issue: issue
  } do
    [first, second] =
      Enum.map(["first_owner", "second_owner"], fn login ->
        {:ok, user} =
          Users.register_oauth_user(%{github_id: "gh_#{login}", login: login, email: "#{login}@example.com"})

        user
      end)

    {:ok, _issue} = Issues.update_issue(issue, %{title: "Still nobody's"})
    refute_enqueued(worker: AdvanceTrackerState)

    {:ok, owned} = Issues.update_issue(issue, %{owner_user_id: first.id})
    assert [%Oban.Job{id: job_id}] = all_enqueued(worker: AdvanceTrackerState, args: %{issue_id: issue.id})

    # Already owned, so its status has not been held back: a new owner or none queues nothing more.
    Repo.delete!(%Oban.Job{id: job_id})
    {:ok, handed_on} = Issues.update_issue(owned, %{owner_user_id: second.id})
    {:ok, _unowned} = Issues.update_issue(handed_on, %{owner_user_id: nil})
    refute_enqueued(worker: AdvanceTrackerState)
  end
end
