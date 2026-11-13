defmodule Rail.Issues.Actions.AssignIssueTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  import Rail.Pipeline.Utils.BuildTask

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Workers.SyncIssue
  alias Rail.Pipeline
  alias Rail.Projects
  alias Rail.Users

  setup do
    key = "Asg#{System.unique_integer([:positive])}"

    {:ok, local} =
      Projects.create_project(system_scope(), %{
        name: "Assigned here",
        github_repo: "example/#{key}",
        github_installation_id: 1,
        tracker: :local,
        key: key,
        default_branch: "main",
        clone_path: "/tmp/#{key}"
      })

    {:ok, teammate} =
      Users.register_oauth_user(%{github_id: "gh_#{key}", login: "mate_#{key}", email: "#{key}@example.com"})

    teammate = teammate |> Ecto.Changeset.change(project_ids: [local.id]) |> Repo.update!()
    {:ok, issue} = Issues.create_issue(system_scope(), local, %{title: "Own me"})

    %{local: local, teammate: teammate, issue: issue, scope: user_scope(project_ids: [local.id])}
  end

  test "assigns someone the owner menu offers, queues the tracker's sync, and unassigns with nil", %{
    teammate: %{id: teammate_id},
    issue: %Issue{id: issue_id} = issue,
    scope: scope
  } do
    assert {:ok, %Issue{id: ^issue_id, owner_user_id: ^teammate_id}} = Issues.assign_issue(scope, issue, teammate_id)
    assert_enqueued(worker: SyncIssue, args: %{issue_id: issue_id})
    assert %Issue{owner_user_id: ^teammate_id} = Repo.get!(Issue, issue_id)

    assert {:ok, %Issue{owner_user_id: nil}} = Issues.assign_issue(scope, issue, nil)
  end

  test "someone the menu would not offer is refused", %{issue: %Issue{id: issue_id} = issue, scope: scope} do
    {:ok, outsider} =
      Users.register_oauth_user(%{github_id: "gh_outsider_asg", login: "outsider_asg", email: "outsider_asg@example.com"})

    assert {:error, :not_assignable} = Issues.assign_issue(scope, issue, outsider.id)
    assert {:error, :not_assignable} = Issues.assign_issue(scope, issue, "usr_missing")
    assert %Issue{owner_user_id: nil} = Repo.get!(Issue, issue_id)
  end

  test "a teammate who disconnected GitHub is refused", %{
    teammate: teammate,
    issue: %Issue{id: issue_id} = issue,
    scope: scope
  } do
    {:ok, %{id: teammate_id}} = Users.unlink_github(Rail.Scope.for_user(teammate))

    assert {:error, :not_assignable} = Issues.assign_issue(scope, issue, teammate_id)
    assert %Issue{owner_user_id: nil} = Repo.get!(Issue, issue_id)
  end

  test "a project the scope cannot open is not found", %{teammate: teammate, issue: issue} do
    assert {:error, :not_found} = Issues.assign_issue(user_scope(project_ids: []), issue, teammate.id)
  end

  test "a split parent's owner reaches its children, and a child keeps its parent's owner", %{
    local: local,
    teammate: %{id: teammate_id},
    issue: parent_issue,
    scope: scope
  } do
    {:ok, parent} = Pipeline.create_task(parent_issue, :split)
    {:ok, child_issue} = Issues.create_issue(system_scope(), local, %{title: "A part", parent: parent_issue})

    local
    |> build_task(child_issue, %{stage: :engineer, split_position: 1, builds_on: []})
    |> Ecto.Changeset.put_change(:parent_task_id, parent.id)
    |> Repo.insert!()

    assert {:error, :split_child} = Issues.assign_issue(scope, child_issue, teammate_id)

    assert {:ok, %Issue{owner_user_id: ^teammate_id}} = Issues.assign_issue(scope, parent_issue, teammate_id)
    assert %Issue{owner_user_id: ^teammate_id} = Repo.reload!(child_issue)
  end
end
