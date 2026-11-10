defmodule Rail.Issues.Actions.EditIssueTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects
  alias Rail.Repo

  setup do
    key = "Edt#{System.unique_integer([:positive])}"

    {:ok, local} =
      Projects.create_project(system_scope(), %{
        name: "Rail-tracked",
        github_repo: "example/#{key}",
        github_installation_id: 1,
        tracker: :local,
        key: key,
        default_branch: "main",
        clone_path: "/tmp/#{key}"
      })

    {:ok, issue} = Issues.create_issue(system_scope(), local, %{title: "Filed as it was", description: "Old"})
    scope = user_scope(project_ids: [local.id])

    %{local: local, issue: issue, scope: scope}
  end

  test "writes the title, description, priority and estimate, and tells open pages after", %{
    issue: %Issue{id: issue_id} = issue,
    scope: scope
  } do
    Phoenix.PubSub.subscribe(Rail.PubSub, "issues")

    assert {:ok, %Issue{id: ^issue_id, title: "Renamed", description: "New **text**", priority: :urgent, estimate: 5}} =
             Issues.edit_issue(scope, issue, %{
               "title" => "Renamed",
               "description" => "New **text**",
               "priority" => "urgent",
               "estimate" => "5"
             })

    assert_receive {:issue_changed, ^issue_id}
    assert %Issue{title: "Renamed", priority: :urgent, estimate: 5} = Repo.get!(Issue, issue_id)
  end

  test "an emptied description is kept as none", %{issue: %Issue{id: issue_id} = issue, scope: scope} do
    assert {:ok, %Issue{description: nil}} = Issues.edit_issue(scope, issue, %{"description" => ""})
    assert %Issue{description: nil} = Repo.get!(Issue, issue_id)
  end

  test "a blank title is refused and the row stays as it was", %{issue: %Issue{id: issue_id} = issue, scope: scope} do
    Phoenix.PubSub.subscribe(Rail.PubSub, "issues")

    assert {:error, changeset} = Issues.edit_issue(scope, issue, %{"title" => "  "})
    assert %{title: ["can't be blank"]} = errors_on(changeset)
    assert %Issue{title: "Filed as it was"} = Repo.get!(Issue, issue_id)
    refute_received {:issue_changed, ^issue_id}
  end

  test "a negative estimate is refused", %{issue: issue, scope: scope} do
    assert {:error, changeset} = Issues.edit_issue(scope, issue, %{"estimate" => "-1"})
    assert %{estimate: ["must be greater than or equal to 0"]} = errors_on(changeset)
  end

  test "sets and clears the parent from an issue of the same project", %{local: local, issue: issue, scope: scope} do
    {:ok, %Issue{id: parent_id, external_id: parent_external_id}} =
      Issues.create_issue(system_scope(), local, %{title: "The parent"})

    assert {:ok, %Issue{parent_external_id: ^parent_external_id}} =
             Issues.edit_issue(scope, issue, %{"parent_id" => parent_id})

    assert {:ok, %Issue{parent_external_id: nil}} = Issues.edit_issue(scope, issue, %{"parent_id" => ""})
    assert {:ok, %Issue{parent_external_id: nil}} = Issues.edit_issue(scope, issue, %{"parent_id" => nil})
  end

  test "a parent_external_id in the attrs is ignored, so only parent_id sets a parent", %{
    local: local,
    issue: %Issue{id: issue_id} = issue,
    scope: scope
  } do
    {:ok, %Issue{external_id: parent_external_id}} = Issues.create_issue(system_scope(), local, %{title: "The parent"})

    assert {:ok, %Issue{parent_external_id: nil}} =
             Issues.edit_issue(scope, issue, %{"parent_external_id" => parent_external_id})

    assert %Issue{parent_external_id: nil} = Repo.get!(Issue, issue_id)
  end

  test "a parent from another project is refused", %{issue: issue, scope: scope} do
    key = "Oth#{System.unique_integer([:positive])}"

    {:ok, other} =
      Projects.create_project(system_scope(), %{
        name: "Another",
        github_repo: "example/#{key}",
        github_installation_id: 1,
        tracker: :local,
        key: key,
        default_branch: "main",
        clone_path: "/tmp/#{key}"
      })

    {:ok, %Issue{id: elsewhere_id}} = Issues.create_issue(system_scope(), other, %{title: "Elsewhere"})

    assert {:error, changeset} = Issues.edit_issue(scope, issue, %{"parent_id" => elsewhere_id})
    assert %{parent_id: ["is not an issue in this project"]} = errors_on(changeset)
  end

  test "the issue itself and an issue two levels below it are refused as its parent", %{
    local: local,
    issue: %Issue{id: issue_id} = issue,
    scope: scope
  } do
    {:ok, child} = Issues.create_issue(system_scope(), local, %{title: "Child", parent: issue})
    {:ok, %Issue{id: grandchild_id}} = Issues.create_issue(system_scope(), local, %{title: "Grandchild", parent: child})

    assert {:error, changeset} = Issues.edit_issue(scope, issue, %{"parent_id" => grandchild_id})
    assert %{parent_id: ["is a sub-issue of this issue"]} = errors_on(changeset)

    assert {:error, changeset} = Issues.edit_issue(scope, issue, %{"parent_id" => issue_id})
    assert %{parent_id: ["can't be the issue itself"]} = errors_on(changeset)

    assert %Issue{parent_external_id: nil} = Repo.get!(Issue, issue_id)
  end

  test "a parent change also writes the fields beside it, or neither", %{local: local, issue: issue, scope: scope} do
    {:ok, child} = Issues.create_issue(system_scope(), local, %{title: "Child", parent: issue})

    assert {:error, _changeset} = Issues.edit_issue(scope, issue, %{"title" => "Renamed", "parent_id" => child.id})
    assert %Issue{title: "Filed as it was"} = Repo.get!(Issue, issue.id)
  end

  test "an issue Linear holds is not edited here", %{project: project} do
    linear =
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: project.id,
        external_id: "lin_edit_1",
        identifier: "EDT-1",
        title: "In Linear",
        state: :todo
      })
      |> Repo.insert!()

    assert {:error, :unsupported} = Issues.edit_issue(system_scope(), linear, %{"title" => "Renamed"})
    assert %Issue{title: "In Linear"} = Repo.get!(Issue, linear.id)
  end

  test "someone who cannot open the project finds nothing", %{issue: issue} do
    assert {:error, :not_found} = Issues.edit_issue(user_scope(project_ids: []), issue, %{"title" => "Renamed"})
  end
end
