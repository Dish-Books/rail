defmodule Rail.Issues.Actions.RemoveTestingImageTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Schemas.TestingImage
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

    {:ok, pictured} =
      done
      |> Issue.testing_images_changeset([
        %TestingImage{url: "https://x/a.png", name: "a.png"},
        %TestingImage{url: "https://x/b.png", name: "b.png"}
      ])
      |> Repo.update()

    Phoenix.PubSub.subscribe(Rail.PubSub, "testing")

    %{issue: pictured, scope: user_scope(project_ids: [project.id])}
  end

  test "takes the picture out and keeps the rest", %{issue: %Issue{id: issue_id} = issue, scope: scope} do
    assert {:ok, %Issue{testing_images: [%TestingImage{name: "b.png"}]}} =
             Issues.remove_testing_image(scope, issue, "https://x/a.png")

    assert %Issue{testing_images: [%TestingImage{name: "b.png"}]} = Repo.get!(Issue, issue_id)
    assert_received {:testing_notes_changed, ^issue_id}
  end

  test "refuses a ticket out of the queue, one that is gone and a project the user cannot open", %{
    issue: issue,
    scope: scope
  } do
    assert {:error, :not_found} = Issues.remove_testing_image(user_scope(), issue, "https://x/a.png")

    {:ok, tested} = Issues.mark_issue_tested(scope, issue)
    assert {:error, :testing_finished} = Issues.remove_testing_image(scope, tested, "https://x/a.png")
    assert %Issue{testing_images: [_a, _b]} = Repo.get!(Issue, issue.id)

    Repo.delete!(tested)
    assert {:error, :not_found} = Issues.remove_testing_image(scope, tested, "https://x/a.png")
  end
end
