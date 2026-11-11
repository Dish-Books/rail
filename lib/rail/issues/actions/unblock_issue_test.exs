defmodule Rail.Issues.Actions.UnblockIssueTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Schemas.IssueRelation
  alias Rail.Projects
  alias Rail.Repo

  setup do
    key = "Ubk#{System.unique_integer([:positive])}"

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

    {:ok, blocker} = Issues.create_issue(system_scope(), local, %{title: "Goes first"})
    {:ok, blocked} = Issues.create_issue(system_scope(), local, %{title: "Waits"})
    scope = user_scope(project_ids: [local.id])
    :ok = Issues.block_issue(scope, blocker, blocked)

    %{blocker: blocker, blocked: blocked, scope: scope}
  end

  test "removes the relation, and removing it again still succeeds", %{
    blocker: %Issue{id: blocker_id} = blocker,
    blocked: %Issue{id: blocked_id} = blocked,
    scope: scope
  } do
    Phoenix.PubSub.subscribe(Rail.PubSub, "issues")

    assert :ok = Issues.unblock_issue(scope, blocker, blocked)
    assert_receive {:issue_relations_changed, [^blocker_id, ^blocked_id]}
    assert [] = Repo.all(IssueRelation)

    assert :ok = Issues.unblock_issue(scope, blocker, blocked)
  end

  test "only the relation pointing the named way is removed", %{blocker: blocker, blocked: blocked, scope: scope} do
    assert :ok = Issues.unblock_issue(scope, blocked, blocker)
    assert [%IssueRelation{}] = Repo.all(IssueRelation)
  end

  test "someone who cannot open the project removes nothing", %{blocker: blocker, blocked: blocked} do
    assert {:error, :not_found} = Issues.unblock_issue(user_scope(project_ids: []), blocker, blocked)
    assert [%IssueRelation{}] = Repo.all(IssueRelation)
  end

  test "issues of two projects have no relation to remove", %{blocker: blocker, blocked: blocked, scope: scope} do
    assert {:error, :not_found} = Issues.unblock_issue(scope, blocker, %{blocked | project_id: "prj_other"})
  end

  test "issues Linear holds keep their relations there", %{blocker: blocker, blocked: blocked, scope: scope} do
    assert {:error, :unsupported} = Issues.unblock_issue(scope, %{blocker | tracker: :linear}, blocked)
  end
end
