defmodule Rail.Issues.Actions.SendIssueToTriageTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects

  setup do
    key = "Sit#{System.unique_integer([:positive])}"

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Sending",
        github_repo: "example/#{key}",
        github_installation_id: 1,
        tracker: :local,
        key: key,
        default_branch: "main",
        clone_path: "/tmp/#{key}"
      })

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{title: "Merge moves the ticket"})
    {:ok, waiting} = Issues.set_issue_status(system_scope(), issue, %{id: "done", name: "Done", state: :done})
    Phoenix.PubSub.subscribe(Rail.PubSub, "issues")

    %{local_project: project, issue: waiting, scope: user_scope(project_ids: [project.id])}
  end

  test "opens a ticket in Triage in the same project with the notes and a link, and the tested one stays Done", %{
    local_project: %{id: project_id},
    issue: %Issue{id: issue_id, identifier: identifier, url: url} = issue,
    scope: scope
  } do
    {:ok, _noted} = Issues.save_testing_notes(scope, issue, "  A branch that only names it moved it too.\n")

    title = "Follow-up to #{identifier}: Merge moves the ticket"
    description = "A branch that only names it moved it too.\n\nFound while testing [#{identifier}](#{url})."

    assert {:ok,
            %Issue{id: created_id, project_id: ^project_id, state: :triage, title: ^title, description: ^description}} =
             Issues.send_issue_to_triage(scope, issue)

    assert %Issue{state: :done, testing_state: :sent_to_triage} = Repo.get!(Issue, issue_id)
    assert_received {:issue_changed, ^issue_id}
    assert_received {:issue_created, ^created_id}
    assert %{issues: []} = Issues.list_issues(project_id: project_id, testing: true)
  end

  test "blank notes refuse and leave the ticket in the queue", %{issue: %Issue{id: issue_id} = issue, scope: scope} do
    assert {:error, :no_notes} = Issues.send_issue_to_triage(scope, issue)

    {:ok, _blank} = Issues.save_testing_notes(scope, issue, " \n ")
    assert {:error, :no_notes} = Issues.send_issue_to_triage(scope, issue)
    assert %Issue{testing_state: :waiting} = Repo.get!(Issue, issue_id)
  end

  test "a second send says testing already finished and opens no second ticket", %{
    local_project: %{id: project_id},
    issue: issue,
    scope: scope
  } do
    {:ok, _noted} = Issues.save_testing_notes(scope, issue, "Broken")
    {:ok, _created} = Issues.send_issue_to_triage(scope, issue)

    assert {:error, :testing_finished} = Issues.send_issue_to_triage(scope, issue)
    assert %{total: 2} = Issues.list_issues(project_id: project_id, show_finished: true)
  end

  test "a scope that cannot open the project, or a ticket that is gone, finds nothing", %{issue: issue} do
    assert {:error, :not_found} = Issues.send_issue_to_triage(user_scope(project_ids: []), issue)
    Repo.delete!(issue)
    assert {:error, :not_found} = Issues.send_issue_to_triage(system_scope(), issue)
  end

  test "a tracker that refuses puts the ticket back in the queue as it was", %{project: project} do
    %Issue{id: issue_id} =
      linear =
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: project.id,
        external_id: "lin_sent_back",
        identifier: "TST-90",
        title: "Refused",
        url: "https://linear.app/issue/TST-90",
        state: :in_review
      })
      |> Repo.insert!()
      |> Issue.tracker_changeset(%{state: :done})
      |> Repo.update!()

    {:ok, _noted} = Issues.save_testing_notes(system_scope(), linear, "Still broken")

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"issueCreate" => %{"success" => false}}})
    end)

    assert {:error, {:linear_mutation_failed, "issueCreate"}} = Issues.send_issue_to_triage(system_scope(), linear)
    assert %Issue{state: :done, testing_state: :testing, testing_notes: "Still broken"} = Repo.get!(Issue, issue_id)
    assert %{issues: [%Issue{id: ^issue_id}]} = Issues.list_issues(project_id: project.id, testing: true)
  end
end
