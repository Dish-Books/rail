defmodule Rail.Issues.Actions.BlockIssueTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Schemas.IssueRelation
  alias Rail.Projects
  alias Rail.Repo

  setup do
    key = "Blk#{System.unique_integer([:positive])}"

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

    %{local: local, blocker: blocker, blocked: blocked, scope: user_scope(project_ids: [local.id])}
  end

  test "records the pair once, added again either way round, and tells open pages", %{
    blocker: %Issue{id: blocker_id} = blocker,
    blocked: %Issue{id: blocked_id} = blocked,
    scope: scope
  } do
    Phoenix.PubSub.subscribe(Rail.PubSub, "issues")

    assert :ok = Issues.block_issue(scope, blocker, blocked)
    assert_receive {:issue_relations_changed, [^blocker_id, ^blocked_id]}

    assert :ok = Issues.block_issue(scope, blocker, blocked)
    assert :ok = Issues.block_issue(scope, blocked, blocker)

    assert [%IssueRelation{blocker_issue_id: ^blocker_id, blocked_issue_id: ^blocked_id}] = Repo.all(IssueRelation)
  end

  test "an issue paired with itself is refused", %{blocker: blocker, scope: scope} do
    assert {:error, changeset} = Issues.block_issue(scope, blocker, blocker)
    assert %{blocked_issue_id: ["can't be the blocking issue"]} = errors_on(changeset)
    assert [] = Repo.all(IssueRelation)
  end

  test "an issue in another project is not found", %{blocked: blocked, scope: scope} do
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

    {:ok, elsewhere} = Issues.create_issue(system_scope(), other, %{title: "Elsewhere"})

    assert {:error, :not_found} = Issues.block_issue(system_scope(), elsewhere, blocked)
    assert {:error, :not_found} = Issues.block_issue(scope, blocked, %{elsewhere | project_id: blocked.project_id})
    assert [] = Repo.all(IssueRelation)
  end

  test "someone who cannot open the project adds nothing", %{blocker: blocker, blocked: blocked} do
    assert {:error, :not_found} = Issues.block_issue(user_scope(project_ids: []), blocker, blocked)
  end

  test "issues Linear holds keep their relations there", %{project: project} do
    [first, second] =
      for n <- 1..2 do
        %Issue{}
        |> Issue.tracker_changeset(%{
          project_id: project.id,
          external_id: "lin_block_#{n}",
          identifier: "BLK-#{n}",
          title: "In Linear #{n}",
          state: :todo
        })
        |> Repo.insert!()
      end

    assert {:error, :unsupported} = Issues.block_issue(system_scope(), first, second)
  end
end
