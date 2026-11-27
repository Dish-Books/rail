defmodule Rail.Issues.Actions.SaveTestingScenarioTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Schemas.TestingScenario
  alias Rail.Projects

  setup do
    key = "Sts#{System.unique_integer([:positive])}"

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

    # The agent's scenarios, which leave the ticket Waiting.
    first = TestingScenario.agent("Open the export")
    second = TestingScenario.agent("Six icons fit")

    {:ok, written} =
      waiting |> Issue.testing_scenarios_changeset([first, second], :agent) |> Repo.update()

    Phoenix.PubSub.subscribe(Rail.PubSub, "issues")
    Phoenix.PubSub.subscribe(Rail.PubSub, "testing")

    %{issue: written, first: first, second: second, scope: user_scope(project_ids: [project.id])}
  end

  test "the first mark reaches the database, moves a Waiting ticket to In testing and says so on both topics", %{
    issue: %Issue{id: issue_id, testing_state: :waiting} = issue,
    first: %{id: first_id},
    second: %{id: second_id},
    scope: scope
  } do
    assert {:ok,
            %Issue{
              testing_state: :testing,
              testing_scenarios: [%TestingScenario{id: ^first_id, result: :passed}, %TestingScenario{result: nil}]
            }} = Issues.save_testing_scenario(scope, issue, first_id, %{"result" => "passed"})

    assert %Issue{testing_scenarios: [%TestingScenario{result: :passed}, %TestingScenario{result: nil}]} =
             Repo.get!(Issue, issue_id)

    assert_received {:testing_changed, ^issue_id}
    assert_received {:issue_changed, ^issue_id}

    assert {:ok, %Issue{testing_scenarios: [_first, %TestingScenario{result: :failed, note: "Cut off"}]}} =
             Issues.save_testing_scenario(scope, issue, second_id, %{result: "failed", note: "Cut off"})

    assert %Issue{testing_scenarios: [_first, %TestingScenario{result: :failed, note: "Cut off"}]} =
             Repo.get!(Issue, issue_id)

    refute_received {:issue_changed, ^issue_id}
  end

  test "switching a Failed scenario to Passed keeps its note", %{issue: issue, first: %{id: first_id}, scope: scope} do
    {:ok, _failed} = Issues.save_testing_scenario(scope, issue, first_id, %{result: "failed", note: "Broken"})

    assert {:ok, %Issue{testing_scenarios: [%TestingScenario{result: :passed, note: "Broken"}, _second]}} =
             Issues.save_testing_scenario(scope, issue, first_id, %{result: "passed"})
  end

  test "an unknown result, a scenario that is gone, or a ticket being written refuses and changes nothing", %{
    issue: %Issue{id: issue_id} = issue,
    first: %{id: first_id},
    scope: scope
  } do
    assert {:error, %Ecto.Changeset{}} = Issues.save_testing_scenario(scope, issue, first_id, %{result: "skipped"})
    assert {:error, :not_found} = Issues.save_testing_scenario(scope, issue, "tsc_gone", %{result: "passed"})

    {:ok, _requested} = Issues.request_test_scenarios(issue, "abc123")
    assert {:error, :writing_scenarios} = Issues.save_testing_scenario(scope, issue, first_id, %{result: "passed"})

    assert %Issue{testing_state: :waiting, testing_scenarios: [%TestingScenario{result: nil}, _second]} =
             Repo.get!(Issue, issue_id)

    refute_received {:testing_changed, ^issue_id}
  end

  test "a stamp more than two hours old no longer holds the ticket", %{
    issue: %Issue{id: issue_id} = issue,
    first: %{id: first_id},
    scope: scope
  } do
    old = DateTime.utc_now() |> DateTime.shift(minute: -121) |> DateTime.truncate(:second)
    Repo.update_all(from(i in Issue, where: i.id == ^issue_id), set: [scenarios_requested_at: old])

    assert {:ok, %Issue{testing_scenarios: [%TestingScenario{result: :passed}, _second]}} =
             Issues.save_testing_scenario(scope, issue, first_id, %{result: "passed"})
  end
end
