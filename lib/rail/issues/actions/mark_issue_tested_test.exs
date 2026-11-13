defmodule Rail.Issues.Actions.MarkIssueTestedTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects

  setup do
    key = "Mit#{System.unique_integer([:positive])}"

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Marking",
        github_repo: "example/#{key}",
        github_installation_id: 1,
        tracker: :local,
        key: key,
        default_branch: "main",
        clone_path: "/tmp/#{key}"
      })

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{title: "Backup reports its size"})
    {:ok, waiting} = Issues.set_issue_status(system_scope(), issue, %{id: "done", name: "Done", state: :done})
    Phoenix.PubSub.subscribe(Rail.PubSub, "issues")

    %{issue: waiting, scope: user_scope(project_ids: [project.id])}
  end

  test "a ticket in the queue reads Tested, stays in Done with its notes and leaves the queue", %{
    issue: %Issue{id: issue_id, project_id: project_id} = issue,
    scope: scope
  } do
    {:ok, _noted} = Issues.save_testing_notes(scope, issue, "Reported 2 GB")

    assert {:ok, %Issue{id: ^issue_id, state: :done, testing_state: :tested, testing_notes: "Reported 2 GB"}} =
             Issues.mark_issue_tested(scope, issue)

    assert_received {:issue_changed, ^issue_id}
    assert %{issues: []} = Issues.list_issues(project_id: project_id, testing: true)
  end

  test "a ticket marked Tested keeps an updated_at no older than the moment it was marked", %{
    issue: issue,
    scope: scope
  } do
    before = DateTime.utc_now()

    assert {:ok, %Issue{testing_state: :tested, updated_at: updated_at}} = Issues.mark_issue_tested(scope, issue)
    assert DateTime.compare(updated_at, before) != :lt
  end

  test "a second call changes nothing and says testing already finished", %{
    issue: %Issue{id: issue_id} = issue,
    scope: scope
  } do
    {:ok, %Issue{updated_at: tested_at}} = Issues.mark_issue_tested(scope, issue)
    assert_received {:issue_changed, ^issue_id}

    assert {:error, :testing_finished} = Issues.mark_issue_tested(scope, issue)
    assert %Issue{testing_state: :tested, updated_at: ^tested_at} = Repo.get!(Issue, issue_id)
    refute_received {:issue_changed, ^issue_id}
  end

  test "a ticket that left Done refuses", %{issue: issue, scope: scope} do
    {:ok, reopened} =
      Issues.set_issue_status(system_scope(), issue, %{id: "in_progress", name: "In Progress", state: :in_progress})

    assert {:error, :testing_finished} = Issues.mark_issue_tested(scope, reopened)
  end

  test "a scope that cannot open the project finds nothing and changes nothing", %{issue: %Issue{id: issue_id} = issue} do
    assert {:error, :not_found} = Issues.mark_issue_tested(user_scope(project_ids: []), issue)
    assert %Issue{testing_state: :waiting} = Repo.get!(Issue, issue_id)
  end
end
