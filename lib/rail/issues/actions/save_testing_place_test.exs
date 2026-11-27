defmodule Rail.Issues.Actions.SaveTestingPlaceTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects

  setup do
    key = "Stp#{System.unique_integer([:positive])}"

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Places",
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

  test "Production or Staging, a platform and a device save one at a time and move the ticket to In testing", %{
    issue: %Issue{id: issue_id} = issue,
    scope: scope
  } do
    assert {:ok, %Issue{testing_state: :testing, testing_environment: :staging}} =
             Issues.save_testing_place(scope, issue, %{"testing_environment" => "staging"})

    assert_received {:issue_changed, ^issue_id}

    assert {:ok, %Issue{testing_environment: :staging, testing_platform: :ios}} =
             Issues.save_testing_place(scope, issue, %{"testing_platform" => "ios"})

    assert {:ok, %Issue{testing_environment: :production, testing_device: "iPhone 15"}} =
             Issues.save_testing_place(scope, issue, %{testing_environment: "production", testing_device: "iPhone 15"})

    assert %Issue{testing_environment: :production, testing_platform: :ios, testing_device: "iPhone 15"} =
             Repo.get!(Issue, issue_id)

    assert_received {:testing_changed, ^issue_id}
  end

  test "Preview is not a place to test and changes nothing", %{issue: %Issue{id: issue_id} = issue, scope: scope} do
    assert {:error, %Ecto.Changeset{} = changeset} =
             Issues.save_testing_place(scope, issue, %{"testing_environment" => "preview"})

    assert %{testing_environment: ["is invalid"]} = errors_on(changeset)
    assert %Issue{testing_environment: nil, testing_state: :waiting} = Repo.get!(Issue, issue_id)
  end

  test "a ticket being written refuses", %{issue: issue, scope: scope} do
    {:ok, _requested} = Issues.request_test_scenarios(issue, "abc123")

    assert {:error, :writing_scenarios} =
             Issues.save_testing_place(scope, issue, %{"testing_environment" => "staging"})
  end
end
