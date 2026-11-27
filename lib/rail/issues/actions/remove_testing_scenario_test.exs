defmodule Rail.Issues.Actions.RemoveTestingScenarioTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Schemas.TestingScenario
  alias Rail.Projects

  setup do
    key = "Rts#{System.unique_integer([:positive])}"

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
    agent = TestingScenario.agent("Wrong guess")
    {:ok, written} = waiting |> Issue.testing_scenarios_changeset([agent], :agent) |> Repo.update()
    Phoenix.PubSub.subscribe(Rail.PubSub, "testing")

    %{issue: written, agent: agent, scope: user_scope(project_ids: [project.id])}
  end

  test "a tester removes the agent's scenario and their own", %{
    issue: %Issue{id: issue_id} = issue,
    agent: %{id: agent_id},
    scope: scope
  } do
    {:ok, %Issue{testing_scenarios: [_agent, %{id: own_id}]}} = Issues.add_testing_scenario(scope, issue, "Mine")

    assert {:ok, %Issue{testing_scenarios: [%TestingScenario{title: "Mine"}]}} =
             Issues.remove_testing_scenario(scope, issue, agent_id)

    assert {:ok, %Issue{testing_scenarios: []}} = Issues.remove_testing_scenario(scope, issue, own_id)
    assert %Issue{testing_scenarios: []} = Repo.get!(Issue, issue_id)
    assert_received {:testing_changed, ^issue_id}
  end

  test "a scenario already gone is no change", %{issue: %Issue{id: issue_id} = issue, scope: scope} do
    assert {:ok, %Issue{testing_state: :waiting, testing_scenarios: [_agent]}} =
             Issues.remove_testing_scenario(scope, issue, "tsc_gone")

    assert %Issue{testing_state: :waiting} = Repo.get!(Issue, issue_id)
  end

  test "a ticket out of the queue refuses and keeps its scenarios", %{issue: issue, agent: %{id: agent_id}, scope: scope} do
    {:ok, _passed} = Issues.save_testing_scenario(scope, issue, agent_id, %{result: "passed"})
    {:ok, _tested} = Issues.mark_issue_tested(scope, issue, %{})

    assert {:error, :testing_finished} = Issues.remove_testing_scenario(scope, issue, agent_id)
    assert %Issue{testing_scenarios: [_agent]} = Repo.get!(Issue, issue.id)
  end
end
