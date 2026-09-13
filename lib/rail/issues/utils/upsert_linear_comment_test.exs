defmodule Rail.Issues.Utils.UpsertLinearCommentTest do
  use Rail.DataCase, async: true

  import Rail.Issues.Utils.UpsertLinearComment

  alias Rail.Issues.Schemas.Comment
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo

  setup do
    # No workspace, so writing the project asks Linear nothing.
    project =
      %Project{}
      |> Project.changeset(%{
        name: "Upsert Comment Project",
        github_repo: "org/upsert-comment",
        github_installation_id: 13_101,
        default_branch: "main",
        linear_team_key: "UPC",
        clone_path: "/tmp/repos/upsert-comment"
      })
      |> Repo.insert!()

    issue =
      %Issue{}
      |> Issue.linear_changeset(%{
        project_id: project.id,
        external_id: "lin_upc_1",
        identifier: "UPC-1",
        title: "Discussed",
        state: :triage
      })
      |> Repo.insert!()

    %{issue: issue}
  end

  test "upserts the comment onto its issue and tells the issue's page", %{issue: %Issue{id: issue_id}} do
    Phoenix.PubSub.subscribe(Rail.PubSub, "issues")

    assert {:ok, %Comment{issue_id: ^issue_id, body: "Hello"}} =
             upsert_linear_comment(%{"id" => "lin_upc_com_1", "body" => "Hello", "issueId" => "lin_upc_1"})

    assert_receive {:issue_comments_changed, ^issue_id}
  end

  test "a comment naming no issue has no issue to go on" do
    assert {:error, :issue_not_found} = upsert_linear_comment(%{"id" => "lin_upc_com_2", "body" => "Lost"})
  end

  test "a reply to a thread Rail has not synced has no parent to go on" do
    assert {:error, :parent_not_found} =
             upsert_linear_comment(%{
               "id" => "lin_upc_com_3",
               "body" => "Reply",
               "issueId" => "lin_upc_1",
               "parentId" => "lin_upc_com_unsynced"
             })

    assert [] = Repo.all(Comment)
  end
end
