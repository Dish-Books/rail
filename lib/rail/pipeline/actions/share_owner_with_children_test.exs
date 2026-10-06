defmodule Rail.Pipeline.Actions.ShareOwnerWithChildrenTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Workers.AdvanceLinearState
  alias Rail.Pipeline
  alias Rail.Scope
  alias Rail.Users

  setup %{project: project} do
    for {identifier, title} <- [{"SOC-1", "Work on SOC-1"}, {"SOC-2", "Child SOC-2"}, {"SOC-3", "Child SOC-3"}] do
      Req.Test.expect(Rail.Linear, fn conn ->
        Req.Test.json(conn, %{
          "data" => %{
            "issueCreate" => %{
              "success" => true,
              "issue" => %{"id" => "lin_#{identifier}", "identifier" => identifier, "title" => title}
            }
          }
        })
      end)
    end

    {:ok, parent_issue} = Issues.create_issue(system_scope(), project, %{title: "Work on SOC-1"})
    {:ok, parent} = Pipeline.create_task(parent_issue, :split)
    parent = Repo.preload(parent, [:issue, :project])

    children =
      for {{identifier, builds_on}, number} <- Enum.with_index([{"SOC-2", []}, {"SOC-3", [1]}], 1) do
        attrs = %{title: "Child #{identifier}", parent: parent_issue}
        {:ok, issue} = Issues.create_issue(system_scope(), project, attrs)
        part = %{number: number, builds_on: builds_on, plan: "## Implementation plan\n\nPart #{number}."}
        {:ok, child} = Pipeline.create_child_task(parent, issue, part)
        Repo.preload(child, [:issue, :project])
      end

    %{parent: parent, children: children}
  end

  test "claiming an unowned split parent gives every child that owner and moves their Linear status", %{
    parent: parent,
    children: [first, second]
  } do
    {:ok, %{id: owner_id} = owner} =
      Users.register_oauth_user(%{github_id: "gh_soc_owner", login: "soc_owner", email: "soc_owner@example.com"})

    owner = owner |> Ecto.Changeset.change(linear_user_id: "lin_usr_soc_owner") |> Repo.update!()
    {:ok, claimed} = Issues.claim_issue(Scope.for_user(owner), parent.issue)

    assert {:ok, [%Issue{owner_user_id: ^owner_id}, %Issue{owner_user_id: ^owner_id}]} =
             Pipeline.share_owner_with_children(claimed)

    for child <- [first, second] do
      assert %Issue{owner_user_id: ^owner_id} = Repo.reload!(child.issue)
      assert_enqueued(worker: AdvanceLinearState, args: %{issue_id: child.issue_id})
    end

    assert {:ok, []} = Pipeline.share_owner_with_children(claimed)
  end

  test "an issue with no split changes nothing", %{children: [first, _second]} do
    assert {:ok, []} = Pipeline.share_owner_with_children(%{first.issue | owner_user_id: "usr_nobody"})
  end
end
