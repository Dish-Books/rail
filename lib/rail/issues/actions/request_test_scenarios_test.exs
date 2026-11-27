defmodule Rail.Issues.Actions.RequestTestScenariosTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Workers.SyncIssue
  alias Rail.Issues.Workers.WriteTestScenarios

  setup %{project: project} do
    {:ok, issue} = Issues.create_issue(system_scope(), project, %{title: "Export keeps icons"})
    {:ok, done} = Issues.set_issue_status(system_scope(), issue, %{id: "done", name: "Done", state: :done})
    %{issue: done}
  end

  test "a merged ticket is stamped as waiting on its scenarios, announced, and its pass queued with the commit", %{
    issue: %Issue{id: issue_id} = issue
  } do
    assert {:ok, %Issue{id: ^issue_id, scenarios_requested_at: %DateTime{microsecond: {0, 0}} = requested_at}} =
             Issues.request_test_scenarios(issue, "3c9a1f0e2b")

    assert %Issue{scenarios_requested_at: ^requested_at} = Repo.get!(Issue, issue_id)
    assert Issue.writing_scenarios?(Repo.get!(Issue, issue_id))
    assert_enqueued(worker: WriteTestScenarios, args: %{issue_id: issue_id, merge_sha: "3c9a1f0e2b"})
    assert_enqueued(worker: SyncIssue, args: %{issue_id: issue_id})
  end

  test "a ticket already Tested or Sent to triage is returned as it is, with no pass queued", %{issue: issue} do
    {:ok, %Issue{id: tested_id}} = Issues.mark_issue_tested(system_scope(), issue, %{no_scenarios_reason: "By hand"})

    assert {:ok, %Issue{id: ^tested_id, testing_state: :tested, scenarios_requested_at: nil}} =
             Issues.request_test_scenarios(issue, "3c9a1f0e2b")

    Repo.update_all(from(i in Issue, where: i.id == ^tested_id), set: [testing_state: :sent_to_triage])

    assert {:ok, %Issue{testing_state: :sent_to_triage, scenarios_requested_at: nil}} =
             Issues.request_test_scenarios(issue, "3c9a1f0e2b")

    refute_enqueued(worker: WriteTestScenarios)
  end
end
