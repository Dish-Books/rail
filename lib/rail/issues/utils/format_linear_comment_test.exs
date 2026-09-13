defmodule Rail.Issues.Utils.FormatLinearCommentTest do
  use ExUnit.Case, async: true

  import Rail.Issues.Utils.FormatLinearComment

  test "reads a comment as the API nests it" do
    assert %{
             external_id: "lin_com_1",
             body: "Reported again",
             author_name: "michael",
             author_avatar_url: "https://avatars/michael.png",
             inserted_at: ~U[2026-09-08 12:00:00.123000Z],
             updated_at: ~U[2026-09-09 08:30:00.000000Z],
             issue_external_id: "lin_iss_1",
             parent_external_id: "lin_com_0",
             author_linear_id: "lin_usr_1"
           } =
             format_linear_comment(%{
               "id" => "lin_com_1",
               "body" => "Reported again",
               "createdAt" => "2026-09-08T12:00:00.123Z",
               "updatedAt" => "2026-09-09T08:30:00Z",
               "issue" => %{"id" => "lin_iss_1"},
               "parent" => %{"id" => "lin_com_0"},
               "user" => %{"id" => "lin_usr_1", "name" => "michael", "avatarUrl" => "https://avatars/michael.png"}
             })
  end

  test "reads a comment as a webhook flattens it" do
    assert %{
             external_id: "lin_com_2",
             issue_external_id: "lin_iss_2",
             parent_external_id: nil,
             author_linear_id: "lin_usr_2",
             inserted_at: ~U[2026-09-08 12:00:00.000000Z],
             updated_at: ~U[2026-09-08 12:00:00.000000Z]
           } =
             format_linear_comment(%{
               "id" => "lin_com_2",
               "body" => "From a webhook",
               "createdAt" => "2026-09-08T12:00:00Z",
               "issueId" => "lin_iss_2",
               "userId" => "lin_usr_2"
             })
  end

  test "a comment by an integration is named for it" do
    assert %{author_name: "GitHub", author_linear_id: nil, body: ""} =
             format_linear_comment(%{"id" => "lin_com_3", "botActor" => %{"name" => "GitHub"}})
  end
end
