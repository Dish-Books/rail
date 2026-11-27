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
        key: key,
        default_branch: "main",
        clone_path: "/tmp/#{key}"
      })

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{title: "Backup reports its size"})
    {:ok, waiting} = Issues.set_issue_status(system_scope(), issue, %{id: "done", name: "Done", state: :done})
    Phoenix.PubSub.subscribe(Rail.PubSub, "issues")

    %{issue: waiting, scope: user_scope(project_ids: [project.id])}
  end

  test "a ticket whose every scenario passed reads Tested, stays in Done with them and leaves the queue", %{
    issue: %Issue{id: issue_id, project_id: project_id} = issue,
    scope: scope
  } do
    {:ok, %Issue{testing_scenarios: [%{id: scenario_id}]}} = Issues.add_testing_scenario(scope, issue, "Reports 2 GB")
    {:ok, _passed} = Issues.save_testing_scenario(scope, issue, scenario_id, %{result: "passed"})

    assert {:ok,
            %Issue{
              id: ^issue_id,
              state: :done,
              testing_state: :tested,
              no_scenarios_reason: nil,
              testing_scenarios: [%{title: "Reports 2 GB", result: :passed}]
            }} = Issues.mark_issue_tested(scope, issue, %{"no_scenarios_reason" => "Ignored with scenarios"})

    assert_received {:issue_changed, ^issue_id}
    assert %{issues: []} = Issues.list_issues(project_id: project_id, testing: true)
  end

  test "a ticket with no scenarios refuses without a reason and keeps the trimmed reason it is given", %{
    issue: %Issue{id: issue_id} = issue,
    scope: scope
  } do
    assert {:error, %Ecto.Changeset{} = changeset} = Issues.mark_issue_tested(scope, issue, %{})
    assert %{no_scenarios_reason: ["Write why there was nothing to test."]} = errors_on(changeset)
    assert {:error, %Ecto.Changeset{}} = Issues.mark_issue_tested(scope, issue, %{"no_scenarios_reason" => "  "})
    assert %Issue{testing_state: :waiting} = Repo.get!(Issue, issue_id)
    refute_received {:issue_changed, ^issue_id}

    assert {:ok, %Issue{testing_state: :tested, no_scenarios_reason: "Only docs changed"}} =
             Issues.mark_issue_tested(scope, issue, %{"no_scenarios_reason" => " Only docs changed \n"})

    assert %Issue{no_scenarios_reason: "Only docs changed"} = Repo.get!(Issue, issue_id)
  end

  test "an unmarked or failed scenario refuses with scenarios_open", %{issue: %Issue{id: issue_id} = issue, scope: scope} do
    {:ok, %Issue{testing_scenarios: [%{id: scenario_id}]}} = Issues.add_testing_scenario(scope, issue, "Reports 2 GB")
    assert {:error, :scenarios_open} = Issues.mark_issue_tested(scope, issue, %{})

    {:ok, _failed} = Issues.save_testing_scenario(scope, issue, scenario_id, %{result: "failed"})
    assert {:error, :scenarios_open} = Issues.mark_issue_tested(scope, issue, %{"no_scenarios_reason" => "Anyway"})
    assert %Issue{testing_state: :testing} = Repo.get!(Issue, issue_id)
  end

  test "a ticket being written refuses", %{issue: %Issue{id: issue_id} = issue, scope: scope} do
    {:ok, _requested} = Issues.request_test_scenarios(issue, "abc123")

    assert {:error, :writing_scenarios} = Issues.mark_issue_tested(scope, issue, %{"no_scenarios_reason" => "Docs"})
    assert %Issue{testing_state: :waiting} = Repo.get!(Issue, issue_id)
  end

  test "a ticket marked Tested keeps an updated_at no older than the moment it was marked", %{
    issue: issue,
    scope: scope
  } do
    before = DateTime.utc_now()

    assert {:ok, %Issue{testing_state: :tested, updated_at: updated_at}} =
             Issues.mark_issue_tested(scope, issue, %{no_scenarios_reason: "Docs"})

    assert DateTime.compare(updated_at, before) != :lt
  end

  test "a second call changes nothing and says testing already finished", %{
    issue: %Issue{id: issue_id} = issue,
    scope: scope
  } do
    {:ok, %Issue{updated_at: tested_at}} = Issues.mark_issue_tested(scope, issue, %{no_scenarios_reason: "Docs"})
    assert_received {:issue_changed, ^issue_id}

    assert {:error, :testing_finished} = Issues.mark_issue_tested(scope, issue, %{no_scenarios_reason: "Again"})

    assert %Issue{testing_state: :tested, updated_at: ^tested_at, no_scenarios_reason: "Docs"} =
             Repo.get!(Issue, issue_id)

    refute_received {:issue_changed, ^issue_id}
  end

  test "a ticket that left Done refuses", %{issue: issue, scope: scope} do
    {:ok, reopened} =
      Issues.set_issue_status(system_scope(), issue, %{id: "in_progress", name: "In Progress", state: :in_progress})

    assert {:error, :testing_finished} = Issues.mark_issue_tested(scope, reopened, %{no_scenarios_reason: "Docs"})
  end

  test "a scope that cannot open the project, or a ticket that is gone, finds nothing and changes nothing", %{
    issue: %Issue{id: issue_id} = issue
  } do
    assert {:error, :not_found} = Issues.mark_issue_tested(user_scope(project_ids: []), issue, %{})
    assert %Issue{testing_state: :waiting} = Repo.get!(Issue, issue_id)

    Repo.delete!(issue)
    assert {:error, :not_found} = Issues.mark_issue_tested(system_scope(), issue, %{no_scenarios_reason: "Docs"})
  end
end
