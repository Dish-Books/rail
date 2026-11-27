defmodule Rail.Issues.Actions.AddTestingScenarioTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Schemas.TestingScenario
  alias Rail.Projects

  setup do
    key = "Ats#{System.unique_integer([:positive])}"

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Scenarios",
        github_repo: "example/#{key}",
        github_installation_id: 1,
        key: key,
        default_branch: "main",
        clone_path: "/tmp/#{key}"
      })

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{title: "Export keeps icons"})
    {:ok, waiting} = Issues.set_issue_status(system_scope(), issue, %{id: "done", name: "Done", state: :done})
    Phoenix.PubSub.subscribe(Rail.PubSub, "issues")
    Phoenix.PubSub.subscribe(Rail.PubSub, "testing")

    %{issue: waiting, scope: user_scope(project_ids: [project.id])}
  end

  test "a tester's scenario goes at the end, unmarked and unlabeled, and moves a Waiting ticket to In testing", %{
    issue: %Issue{id: issue_id} = issue,
    scope: scope
  } do
    assert {:ok, %Issue{testing_state: :testing, testing_scenarios: [%TestingScenario{title: "Six icons fit"}]}} =
             Issues.add_testing_scenario(scope, issue, " Six icons fit ")

    assert_received {:testing_changed, ^issue_id}
    assert_received {:issue_changed, ^issue_id}

    assert {:ok,
            %Issue{
              testing_scenarios: [
                %TestingScenario{title: "Six icons fit"},
                %TestingScenario{title: "Seven wrap", source: :tester, result: nil}
              ]
            }} = Issues.add_testing_scenario(scope, issue, "Seven wrap")

    assert %Issue{testing_scenarios: [_six, %TestingScenario{title: "Seven wrap"}]} = Repo.get!(Issue, issue_id)
    refute_received {:issue_changed, ^issue_id}
  end

  test "a blank scenario is the changeset's error and changes nothing", %{
    issue: %Issue{id: issue_id} = issue,
    scope: scope
  } do
    assert {:error, %Ecto.Changeset{} = changeset} = Issues.add_testing_scenario(scope, issue, "   ")
    assert %{title: ["can't be blank"]} = errors_on(changeset)
    assert %Issue{testing_state: :waiting, testing_scenarios: []} = Repo.get!(Issue, issue_id)
    refute_received {:testing_changed, ^issue_id}
  end

  test "a ticket being written, out of the queue, gone or in a project the user cannot open refuses", %{
    issue: %Issue{id: issue_id} = issue,
    scope: scope
  } do
    {:ok, _requested} = Issues.request_test_scenarios(issue, "abc123")
    assert {:error, :writing_scenarios} = Issues.add_testing_scenario(scope, issue, "Too soon")

    Repo.update_all(from(i in Issue, where: i.id == ^issue_id), set: [scenarios_requested_at: nil])
    assert {:error, :not_found} = Issues.add_testing_scenario(user_scope(project_ids: []), issue, "Hidden")

    {:ok, _tested} = Issues.mark_issue_tested(scope, issue, %{no_scenarios_reason: "Only docs"})
    assert {:error, :testing_finished} = Issues.add_testing_scenario(scope, issue, "Too late")

    Repo.delete!(issue)
    assert {:error, :not_found} = Issues.add_testing_scenario(scope, issue, "Gone")
  end
end
