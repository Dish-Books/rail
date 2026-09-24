defmodule Rail.Issues.Actions.UpdateIssueTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Workers.SyncIssue

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
end
