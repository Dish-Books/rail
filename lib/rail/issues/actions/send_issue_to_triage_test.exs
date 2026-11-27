defmodule Rail.Issues.Actions.SendIssueToTriageTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Schemas.TestingImage
  alias Rail.Issues.Schemas.TestingScenario
  alias Rail.Projects

  setup do
    key = "Sit#{System.unique_integer([:positive])}"

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Sending",
        github_repo: "example/#{key}",
        github_installation_id: 1,
        key: key,
        default_branch: "main",
        clone_path: "/tmp/#{key}"
      })

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{title: "Merge moves the ticket"})
    {:ok, waiting} = Issues.set_issue_status(system_scope(), issue, %{id: "done", name: "Done", state: :done})

    scenarios = [
      %{TestingScenario.agent("A branch that names it moves it") | result: :passed, note: "Was broken, then fixed"},
      %{
        TestingScenario.agent("A branch that only mentions it leaves it")
        | result: :failed,
          note: "  It moved anyway.\n",
          images: [
            %TestingImage{url: "https://x/a.png", name: "row [cut].png"},
            %TestingImage{url: "https://x/b.png", name: "b.png"}
          ]
      },
      TestingScenario.agent("A second tab shows the move")
    ]

    {:ok, written} = waiting |> Issue.testing_scenarios_changeset(scenarios, :agent) |> Repo.update()
    Phoenix.PubSub.subscribe(Rail.PubSub, "issues")

    %{local_project: project, issue: written, scope: user_scope(project_ids: [project.id])}
  end

  test "opens a ticket in Triage with every result, the failed scenarios' details, the place and a link", %{
    local_project: %{id: project_id},
    issue: %Issue{id: issue_id, identifier: identifier, url: url} = issue,
    scope: scope
  } do
    {:ok, _placed} =
      Issues.save_testing_place(scope, issue, %{
        testing_environment: "staging",
        testing_platform: "ios",
        testing_device: " iPhone 15 "
      })

    title = "Follow-up to #{identifier}: Merge moves the ticket"

    description =
      """
      Found while testing [#{identifier}](#{url}) on Staging · iOS · iPhone 15.

      ## Results

      1 passed · 1 failed · 1 not marked

      - Passed: A branch that names it moves it
      - Failed: A branch that only mentions it leaves it
      - Not marked: A second tab shows the move

      ## Failed scenarios

      1. A branch that only mentions it leaves it

         It moved anyway.

         ![row cut.png](https://x/a.png)

         ![b.png](https://x/b.png)\
      """

    assert {:ok, %Issue{id: created_id, project_id: ^project_id, state: :todo, title: ^title, description: ^description}} =
             Issues.send_issue_to_triage(scope, issue)

    refute description =~ "Was broken, then fixed"
    assert %Issue{state: :done, testing_state: :sent_to_triage} = Repo.get!(Issue, issue_id)
    assert_received {:issue_changed, ^issue_id}
    assert_received {:issue_created, ^created_id}
    assert %{issues: []} = Issues.list_issues(project_id: project_id, testing: true)
  end

  test "notes and pictures from before scenarios follow the failed ones, and no place says nothing of one", %{
    issue: %Issue{id: issue_id, identifier: identifier, url: url} = issue,
    scope: scope
  } do
    Repo.update_all(from(i in Issue, where: i.id == ^issue_id),
      set: [testing_notes: " Old notes \n", testing_images: [%TestingImage{url: "https://x/old.png", name: "old.png"}]]
    )

    assert {:ok, %Issue{description: description}} = Issues.send_issue_to_triage(scope, issue)
    assert description =~ "Found while testing [#{identifier}](#{url}).\n\n## Results"

    assert String.ends_with?(
             description,
             "\n\n## Notes from before scenarios\n\nOld notes\n\n![old.png](https://x/old.png)"
           )
  end

  test "with no failed scenario it refuses, opens nothing and leaves the ticket in the queue", %{
    local_project: %{id: project_id},
    issue: %Issue{id: issue_id, testing_scenarios: [_passed, %{id: failed_id}, _open]} = issue,
    scope: scope
  } do
    {:ok, _passed} = Issues.save_testing_scenario(scope, issue, failed_id, %{result: "passed"})

    assert {:error, :no_failed_scenarios} = Issues.send_issue_to_triage(scope, issue)
    assert %Issue{testing_state: :testing} = Repo.get!(Issue, issue_id)
    assert %{total: 1} = Issues.list_issues(project_id: project_id, show_finished: true)
  end

  test "a ticket being written refuses", %{issue: issue, scope: scope} do
    {:ok, _requested} = Issues.request_test_scenarios(issue, "abc123")
    assert {:error, :writing_scenarios} = Issues.send_issue_to_triage(scope, issue)
  end

  test "a second send says testing already finished and opens no second ticket", %{
    local_project: %{id: project_id},
    issue: issue,
    scope: scope
  } do
    {:ok, _created} = Issues.send_issue_to_triage(scope, issue)

    assert {:error, :testing_finished} = Issues.send_issue_to_triage(scope, issue)
    assert %{total: 2} = Issues.list_issues(project_id: project_id, show_finished: true)
  end

  test "a scope that cannot open the project, or a ticket that is gone, finds nothing", %{issue: issue} do
    assert {:error, :not_found} = Issues.send_issue_to_triage(user_scope(project_ids: []), issue)
    Repo.delete!(issue)
    assert {:error, :not_found} = Issues.send_issue_to_triage(system_scope(), issue)
  end

  test "a send cut off while the new ticket is opened leaves the ticket in the queue with its scenarios", %{
    local_project: %{id: project_id},
    issue: %Issue{id: issue_id} = issue,
    scope: scope
  } do
    expect(Rail.Issues.Tracker, :create_issue, fn _scope, _project, _attrs -> raise "the node restarted" end)

    assert_raise RuntimeError, "the node restarted", fn -> Issues.send_issue_to_triage(scope, issue) end

    assert %Issue{state: :done, testing_state: :waiting, testing_scenarios: [_passed, _failed, _open]} =
             Repo.get!(Issue, issue_id)

    assert %{issues: [%Issue{id: ^issue_id}]} = Issues.list_issues(project_id: project_id, testing: true)
  end
end
