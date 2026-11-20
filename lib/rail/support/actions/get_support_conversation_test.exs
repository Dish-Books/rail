defmodule Rail.Support.Actions.GetSupportConversationTest do
  use Rail.DataCase, async: true

  alias Rail.Intercom
  alias Rail.Projects.Schemas.Project
  alias Rail.Support
  alias Rail.Support.Schemas.Conversation
  alias Rail.Support.Schemas.IntercomWorkspace
  alias Rail.Support.Schemas.Message

  setup %{project: project} do
    Req.Test.expect(Intercom, &Req.Test.json(&1, %{"app" => %{"id_code" => "app_#{System.unique_integer([:positive])}"}}))

    {:ok, workspace} =
      Support.create_intercom_workspace(system_scope(), project, %{
        "name" => "Support",
        "access_token" => "tok",
        "client_id" => "cid",
        "client_secret" => "sec"
      })

    Req.Test.expect(Intercom, fn conn ->
      Req.Test.json(conn, %{
        "id" => "c1",
        "created_at" => 1_790_000_000,
        "updated_at" => 1_790_000_100,
        "source" => %{"id" => "s1", "author" => %{"type" => "user", "name" => "Marta"}, "body" => "First"},
        "conversation_parts" => %{
          "conversation_parts" => [
            %{
              "id" => "p1",
              "part_type" => "comment",
              "created_at" => 1_790_000_060,
              "author" => %{"type" => "admin"},
              "body" => "A minute later"
            }
          ]
        }
      })
    end)

    {:ok, %Conversation{id: conversation_id}} = Support.sync_intercom_conversation(workspace, "c1")
    %{conversation_id: conversation_id, workspace_id: workspace.id}
  end

  test "loads the conversation with everything its page shows, messages oldest first", %{
    conversation_id: conversation_id,
    workspace_id: workspace_id,
    project: %{id: project_id}
  } do
    assert {:ok,
            %Conversation{
              id: ^conversation_id,
              project: %Project{id: ^project_id},
              intercom_workspace: %IntercomWorkspace{id: ^workspace_id},
              reply_posted_by: nil,
              done_by: nil,
              messages: [%Message{external_id: "s1"}, %Message{external_id: "p1"}],
              items: [],
              chat_messages: []
            }} = Support.get_support_conversation(user_scope(project_ids: [project_id]), conversation_id)
  end

  test "a conversation in a project the scope cannot see, or one that is gone, is not found", %{
    conversation_id: conversation_id
  } do
    assert {:error, :not_found} = Support.get_support_conversation(user_scope(project_ids: []), conversation_id)
    assert {:error, :not_found} = Support.get_support_conversation(system_scope(), "scv_gone")
  end
end
