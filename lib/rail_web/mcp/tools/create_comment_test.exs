defmodule RailWeb.Mcp.Tools.CreateCommentTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Schemas.Comment
  alias Rail.Projects
  alias Rail.Scope
  alias Rail.Users

  setup do
    key = "MCC#{System.unique_integer([:positive])}"

    {:ok, local} =
      Projects.create_project(system_scope(), %{
        name: "Commented",
        github_repo: "example/#{key}",
        github_installation_id: 1,
        tracker: :local,
        key: key,
        default_branch: "main",
        clone_path: "/tmp/#{key}"
      })

    {:ok, user} =
      Users.register_oauth_user(%{github_id: "mcc_#{key}", login: "mcc_#{key}", name: "Mcc", email: "#{key}@example.com"})

    {:ok, user} = Users.update_user(system_scope(), user, %{project_ids: [local.id]})
    {:ok, issue} = Issues.create_issue(system_scope(), local, %{title: "Talk about me"})
    %{issue: issue, user: user, scope: Scope.for_user(user)}
  end

  test "posts the comment as the person", %{
    issue: %{id: issue_id, identifier: identifier},
    user: %{id: user_id},
    scope: scope
  } do
    assert {:ok, %{"comment" => %{"identifier" => ^identifier, "body" => "Looks right"}}} =
             call_mcp_tool(scope, "create_comment", %{"identifier" => identifier, "body" => "  Looks right "})

    assert [%Comment{author_user_id: ^user_id, body: "Looks right"}] = Repo.all(where(Comment, issue_id: ^issue_id))
  end

  test "posts nothing that is empty, or on a ticket the person cannot open", %{
    issue: %{id: issue_id} = issue,
    scope: scope
  } do
    assert {:error, "The comment is empty, so nothing was posted."} =
             call_mcp_tool(scope, "create_comment", %{"identifier" => issue.identifier, "body" => "  "})

    assert {:error, "No ticket " <> _rest} =
             call_mcp_tool(user_scope(project_ids: []), "create_comment", %{
               "identifier" => issue.identifier,
               "body" => "Hi"
             })

    assert [] = Repo.all(where(Comment, issue_id: ^issue_id))
  end
end
