defmodule Rail.Issues.Actions.ResetIssueStateTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Workers.SyncIssue

  setup %{project: project} do
    issue =
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: project.id,
        identifier: "RST-1",
        title: "Reset",
        state: :in_review
      })
      |> Repo.insert!()

    %{issue: issue}
  end

  test "moves the issue back to todo, telling no page itself", %{
    issue: %Issue{id: issue_id} = issue
  } do
    Phoenix.PubSub.subscribe(Rail.PubSub, "issues")

    assert {:ok, %Issue{id: ^issue_id, state: :todo}} = Issues.reset_issue_state(issue, :todo)
    assert %Issue{state: :todo} = Repo.get!(Issue, issue_id)
    assert_enqueued(worker: SyncIssue, args: %{issue_id: issue_id})
    refute_receive {:issue_changed, ^issue_id}, 50
  end

  test "moves an issue in review back to in progress", %{issue: %Issue{id: issue_id} = issue} do
    assert {:ok, %Issue{id: ^issue_id, state: :in_progress}} =
             Issues.reset_issue_state(issue, :in_progress)

    assert %Issue{state: :in_progress} = Repo.get!(Issue, issue_id)
    assert_enqueued(worker: SyncIssue, args: %{issue_id: issue_id})
  end

  # A page can show a status the row has already left, so open pages hear of the reset whatever the row read.
  test "tells open pages even when the issue already reads todo", %{issue: issue} do
    %Issue{id: issue_id} = todo = issue |> Ecto.Changeset.change(state: :todo) |> Repo.update!()

    assert {:ok, %Issue{state: :todo}} = Issues.reset_issue_state(todo, :todo)
    assert_enqueued(worker: SyncIssue, args: %{issue_id: issue_id})
  end
end
