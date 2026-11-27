defmodule Rail.Issues.Actions.RemoveTestingImageTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Schemas.TestingImage
  alias Rail.Issues.Schemas.TestingScenario
  alias Rail.Projects

  setup do
    key = "Rti#{System.unique_integer([:positive])}"

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Pictures",
        github_repo: "example/#{key}",
        github_installation_id: 1,
        key: key,
        default_branch: "main",
        clone_path: "/tmp/#{key}"
      })

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{title: "Export keeps icons"})
    {:ok, done} = Issues.set_issue_status(system_scope(), issue, %{id: "done", name: "Done", state: :done})

    pictured = %{
      TestingScenario.agent("Six icons fit")
      | result: :failed,
        images: [
          %TestingImage{url: "https://x/a.png", name: "a.png"},
          %TestingImage{url: "https://x/b.png", name: "b.png"}
        ]
    }

    other = %{TestingScenario.agent("Seven wrap") | images: [%TestingImage{url: "https://x/a.png", name: "a.png"}]}
    {:ok, written} = done |> Issue.testing_scenarios_changeset([pictured, other], :agent) |> Repo.update()
    Phoenix.PubSub.subscribe(Rail.PubSub, "testing")

    %{issue: written, pictured: pictured, scope: user_scope(project_ids: [project.id])}
  end

  test "takes the picture out of its scenario and keeps the rest", %{
    issue: %Issue{id: issue_id} = issue,
    pictured: %{id: pictured_id},
    scope: scope
  } do
    assert {:ok,
            %Issue{
              testing_scenarios: [
                %TestingScenario{images: [%TestingImage{name: "b.png"}]},
                %TestingScenario{images: [%TestingImage{name: "a.png"}]}
              ]
            }} = Issues.remove_testing_image(scope, issue, pictured_id, "https://x/a.png")

    assert %Issue{testing_scenarios: [%TestingScenario{images: [%TestingImage{name: "b.png"}]}, _other]} =
             Repo.get!(Issue, issue_id)

    assert_received {:testing_changed, ^issue_id}
  end

  test "refuses a ticket out of the queue, one that is gone and a project the user cannot open", %{
    issue: issue,
    pictured: %{id: pictured_id},
    scope: scope
  } do
    assert {:error, :not_found} = Issues.remove_testing_image(user_scope(), issue, pictured_id, "https://x/a.png")

    {:ok, reopened} =
      Issues.set_issue_status(system_scope(), issue, %{id: "in_progress", name: "In Progress", state: :in_progress})

    assert {:error, :testing_finished} = Issues.remove_testing_image(scope, reopened, pictured_id, "https://x/a.png")
    assert %Issue{testing_scenarios: [%TestingScenario{images: [_a, _b]}, _other]} = Repo.get!(Issue, issue.id)

    Repo.delete!(reopened)
    assert {:error, :not_found} = Issues.remove_testing_image(scope, reopened, pictured_id, "https://x/a.png")
  end
end
