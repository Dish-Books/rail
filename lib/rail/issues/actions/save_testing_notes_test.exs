defmodule Rail.Issues.Actions.SaveTestingNotesTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects

  setup do
    key = "Stn#{System.unique_integer([:positive])}"

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Notes",
        github_repo: "example/#{key}",
        github_installation_id: 1,
        tracker: :local,
        key: key,
        default_branch: "main",
        clone_path: "/tmp/#{key}"
      })

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{title: "Export keeps icons"})
    {:ok, waiting} = Issues.set_issue_status(system_scope(), issue, %{id: "done", name: "Done", state: :done})
    scope = user_scope(project_ids: [project.id])
    Phoenix.PubSub.subscribe(Rail.PubSub, "issues")
    Phoenix.PubSub.subscribe(Rail.PubSub, "testing")

    %{issue: waiting, scope: scope}
  end

  test "notes that are not blank move a Waiting ticket to In testing and say so on both topics", %{
    issue: %Issue{id: issue_id, testing_state: :waiting} = issue,
    scope: scope
  } do
    assert {:ok, %Issue{id: ^issue_id, testing_state: :testing, testing_notes: "Six icons fit"}} =
             Issues.save_testing_notes(scope, issue, "Six icons fit")

    assert %Issue{testing_state: :testing, testing_notes: "Six icons fit"} = Repo.get!(Issue, issue_id)
    assert_received {:testing_notes_changed, ^issue_id}
    assert_received {:issue_changed, ^issue_id}

    assert {:ok, %Issue{testing_state: :testing, testing_notes: "Seven do not"}} =
             Issues.save_testing_notes(scope, issue, "Seven do not")

    assert_received {:testing_notes_changed, ^issue_id}
    refute_received {:issue_changed, ^issue_id}
  end

  test "blank notes are saved and leave the ticket Waiting, telling only the testing page", %{
    issue: %Issue{id: issue_id} = issue,
    scope: scope
  } do
    assert {:ok, %Issue{testing_state: :waiting, testing_notes: "  \n"}} = Issues.save_testing_notes(scope, issue, "  \n")
    assert_received {:testing_notes_changed, ^issue_id}
    refute_received {:issue_changed, ^issue_id}
  end

  test "a ticket out of the queue refuses and keeps its notes", %{issue: %Issue{id: issue_id} = issue, scope: scope} do
    {:ok, _noted} = Issues.save_testing_notes(scope, issue, "Passed")
    {:ok, _tested} = Issues.mark_issue_tested(scope, issue)

    assert {:error, :testing_finished} = Issues.save_testing_notes(scope, issue, "Overwritten")
    assert %Issue{testing_state: :tested, testing_notes: "Passed"} = Repo.get!(Issue, issue_id)
  end

  test "a ticket not in Done refuses, though it starts Waiting", %{scope: scope, issue: issue} do
    {:ok, open} = Issues.create_issue(system_scope(), Repo.preload(issue, :project).project, %{title: "Still open"})
    assert {:error, :testing_finished} = Issues.save_testing_notes(scope, open, "Nothing to test")
  end

  test "a scope that cannot open the project, or a ticket that is gone, finds nothing", %{issue: issue} do
    assert {:error, :not_found} = Issues.save_testing_notes(user_scope(project_ids: []), issue, "Hidden")
    Repo.delete!(issue)
    assert {:error, :not_found} = Issues.save_testing_notes(system_scope(), issue, "Gone")
  end
end
