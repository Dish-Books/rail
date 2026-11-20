defmodule Rail.Support.Actions.ListSupportConversationsTest do
  use Rail.DataCase, async: true

  alias Rail.Intercom
  alias Rail.Repo
  alias Rail.Support
  alias Rail.Support.Schemas.Conversation
  alias Rail.Support.Schemas.Message

  setup %{project: project, github_project: github_project} do
    unique = System.unique_integer([:positive])

    [workspace, other_workspace] =
      for {owner, n} <- [{project, 1}, {github_project, 2}] do
        Req.Test.expect(Intercom, &Req.Test.json(&1, %{"app" => %{"id_code" => "app_#{unique}_#{n}"}}))

        {:ok, workspace} =
          Support.create_intercom_workspace(system_scope(), owner, %{
            "name" => "Support #{n}",
            "access_token" => "tok",
            "client_id" => "cid",
            "client_secret" => "sec"
          })

        workspace
      end

    conversations =
      for {name, at, owner} <- [
            {"waiting", 1_790_000_100, workspace},
            {"drafting", 1_790_000_200, workspace},
            {"done", 1_790_000_300, workspace},
            {"other", 1_790_000_400, other_workspace}
          ],
          into: %{} do
        Req.Test.expect(Intercom, fn conn ->
          Req.Test.json(conn, %{
            "id" => name,
            "created_at" => at,
            "updated_at" => at,
            "source" => %{
              "id" => "s_#{name}",
              "author" => %{"type" => "user", "name" => name},
              "body" => "First from #{name}"
            },
            "conversation_parts" => %{
              "conversation_parts" => [
                %{
                  "id" => "p_#{name}",
                  "part_type" => "comment",
                  "created_at" => at + 5,
                  "author" => %{"type" => "user"},
                  "body" => "Later"
                }
              ]
            }
          })
        end)

        {:ok, conversation} = Support.sync_intercom_conversation(owner, name)
        {name, conversation}
      end

    Repo.update_all(from(c in Conversation, where: c.id == ^conversations["drafting"].id),
      set: [drafting_since: DateTime.utc_now()]
    )

    Repo.update_all(from(c in Conversation, where: c.id == ^conversations["done"].id), set: [status: :done])

    %{ids: Map.new(conversations, fn {name, conversation} -> {name, conversation.id} end)}
  end

  test "Waiting leaves out what the agent is drafting and what is done, newest first, with the first message", %{
    ids: %{"waiting" => waiting_id, "other" => other_id}
  } do
    assert [
             %Conversation{id: ^other_id},
             %Conversation{id: ^waiting_id, messages: [%Message{text: "First from waiting"}]}
           ] = Support.list_support_conversations()
  end

  test "Drafting and Done hold their own", %{ids: %{"drafting" => drafting_id, "done" => done_id}} do
    assert [%Conversation{id: ^drafting_id}] = Support.list_support_conversations(status: :drafting)
    assert [%Conversation{id: ^done_id}] = Support.list_support_conversations(status: :done)
  end

  test "a project, or a list of them, narrows the queue", %{
    ids: %{"waiting" => waiting_id, "other" => other_id},
    project: %{id: project_id},
    github_project: %{id: github_project_id}
  } do
    assert [%Conversation{id: ^waiting_id}] = Support.list_support_conversations(project_id: project_id)
    assert [%Conversation{id: ^other_id}] = Support.list_support_conversations(project_id: [github_project_id], limit: 5)
  end
end
