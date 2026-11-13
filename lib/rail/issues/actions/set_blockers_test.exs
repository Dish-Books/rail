defmodule Rail.Issues.Actions.SetBlockersTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Schemas.IssueRelation
  alias Rail.Projects

  setup do
    key = "Sbl#{System.unique_integer([:positive])}"

    {:ok, local} =
      Projects.create_project(system_scope(), %{
        name: "Blocked here",
        github_repo: "example/#{key}",
        github_installation_id: 1,
        tracker: :local,
        key: key,
        default_branch: "main",
        clone_path: "/tmp/#{key}"
      })

    issues =
      for title <- ["Waits", "First", "Second", "Third"],
          do: elem(Issues.create_issue(system_scope(), local, %{title: title}), 1)

    blocked_by = fn %Issue{id: id} ->
      Repo.all(from(r in IssueRelation, where: r.blocked_issue_id == ^id, select: r.blocker_issue_id))
    end

    %{issues: issues, scope: user_scope(project_ids: [local.id]), blocked_by: blocked_by}
  end

  test "adds and removes relations until the list is what blocks the issue", %{
    issues: [issue, %{id: first_id} = first, %{id: second_id} = second, %{id: third_id} = third],
    scope: scope,
    blocked_by: blocked_by
  } do
    Phoenix.PubSub.subscribe(Rail.PubSub, "issues")

    assert {:ok, %Issue{}} = Issues.set_blockers(scope, issue, [first, second, first])
    assert Enum.sort([first_id, second_id]) == Enum.sort(blocked_by.(issue))

    assert {:ok, %Issue{}} = Issues.set_blockers(scope, issue, [second, third])
    assert Enum.sort([second_id, third_id]) == Enum.sort(blocked_by.(issue))
    assert_receive {:issue_relations_changed, [^first_id, _issue_id]}

    assert {:ok, %Issue{}} = Issues.set_blockers(scope, issue, [])
    assert [] = blocked_by.(issue)
  end

  test "naming a ticket this one blocks writes nothing", %{
    issues: [issue, first, %{identifier: second_identifier} = second, _third],
    scope: scope,
    blocked_by: blocked_by
  } do
    :ok = Issues.block_issue(scope, issue, second)

    assert {:error, {:already_blocks, [^second_identifier]}} = Issues.set_blockers(scope, issue, [first, second])
    assert [] = blocked_by.(issue)
  end

  test "a write the relation refuses stops there", %{issues: [issue | _others], scope: scope} do
    assert {:error, %Ecto.Changeset{}} = Issues.set_blockers(scope, issue, [issue])
  end

  test "another tracker's ticket is unsupported, and a project the scope cannot open is not found", %{
    project: linear,
    issues: [issue | _others]
  } do
    linear_issue =
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: linear.id,
        external_id: "lin_sbl",
        identifier: "TST-9301",
        title: "Linear",
        state: :todo
      })
      |> Repo.insert!()

    assert {:error, :unsupported} = Issues.set_blockers(system_scope(), linear_issue, [])
    assert {:error, :not_found} = Issues.set_blockers(user_scope(project_ids: []), issue, [])
  end
end
