defmodule Rail.Issues.Actions.AdvanceIssueStateTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Issues
  alias Rail.Issues.Workers.AdvanceLinearState

  setup %{project: project} do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_advance_action_1", "identifier" => "ADA-1", "title" => "Advance Action Issue"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Advance Action Issue"})

    %{issue: issue}
  end

  test "queues the Linear move rather than making it", %{issue: issue} do
    assert {:ok, %Oban.Job{}} = Issues.advance_issue_state(issue, :in_review)

    assert_enqueued(worker: AdvanceLinearState, args: %{issue_id: issue.id, state: "in_review"})
  end
end
