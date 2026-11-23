defmodule Rail.Issues.Actions.CommentTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Schemas.Comment
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Users

  setup do
    key = "Cmt#{System.unique_integer([:positive])}"

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Commented",
        github_repo: "example/#{key}",
        github_installation_id: 1,
        key: key,
        default_branch: "main",
        clone_path: "/tmp/#{key}"
      })

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{title: "Talk about it"})
    Phoenix.PubSub.subscribe(Rail.PubSub, "issues")

    %{issue: issue}
  end

  test "a comment and its reply are kept under the commenter's name and shown at once", %{
    issue: %{id: issue_id} = issue
  } do
    {:ok, %{id: user_id} = user} =
      Users.register_oauth_user(%{github_id: "gh_local_commenter", login: "local-commenter", email: "lc@example.com"})

    assert {:ok, %Comment{id: comment_id, issue_id: ^issue_id, author_user_id: ^user_id, body: "Looks right"}} =
             Issues.comment(Scope.for_user(user), issue, %{body: "Looks right"})

    assert_receive {:issue_comments_changed, ^issue_id}

    assert {:ok, %Comment{issue_id: ^issue_id, parent_id: ^comment_id, author_user_id: ^user_id, body: "Agreed"}} =
             Issues.comment(Scope.for_user(user), issue, %{body: "Agreed", parent_id: comment_id})

    assert_receive {:issue_comments_changed, ^issue_id}
  end

  test "a comment from Rail itself has no author, and each comment gets an id of its own", %{
    issue: %{id: issue_id} = issue
  } do
    assert {:ok, %Comment{author_user_id: nil, author_name: "Rail", id: first}} =
             Issues.comment(system_scope(), issue, %{body: "Plan approved"})

    assert {:ok, %Comment{id: second}} = Issues.comment(system_scope(), issue, %{body: "Merged"})
    assert first != second
    assert [%Comment{}, %Comment{}] = Repo.all(from c in Comment, where: c.issue_id == ^issue_id)
  end

  test "won't reply to a comment that isn't a thread on this issue", %{issue: issue} do
    assert {:error, :parent_not_found} =
             Issues.comment(Scope.for_system(), issue, %{body: "yes", parent_id: "com_missing"})

    assert [] = Repo.all(Comment)
  end
end
