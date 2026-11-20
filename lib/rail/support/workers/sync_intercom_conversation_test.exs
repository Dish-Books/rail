defmodule Rail.Support.Workers.SyncIntercomConversationTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Intercom
  alias Rail.Support
  alias Rail.Support.Schemas.Conversation
  alias Rail.Support.Workers.RunSupportAgent
  alias Rail.Support.Workers.SyncIntercomConversation

  setup %{project: project} do
    app_id = "app_#{System.unique_integer([:positive])}"
    Req.Test.expect(Intercom, &Req.Test.json(&1, %{"app" => %{"id_code" => app_id}}))

    {:ok, workspace} =
      Support.create_intercom_workspace(system_scope(), project, %{
        "name" => "Support",
        "access_token" => "tok",
        "client_id" => "cid",
        "client_secret" => "sec"
      })

    payload = %{
      "id" => "c1",
      "created_at" => 1_790_000_000,
      "updated_at" => 1_790_000_000,
      "state" => "closed",
      "source" => %{"id" => "s1", "author" => %{"type" => "user", "name" => "Marta"}, "body" => "Help"}
    }

    %{workspace: workspace, payload: payload}
  end

  test "a customer's notice syncs the conversation and asks for a draft", %{workspace: workspace, payload: payload} do
    Req.Test.expect(Intercom, &Req.Test.json(&1, payload))

    assert {:ok, %Conversation{id: conversation_id, status: :waiting, drafting_since: %DateTime{}}} =
             perform_job(SyncIntercomConversation, %{
               "workspace_id" => workspace.id,
               "external_id" => "c1",
               "draft" => true,
               "imported" => false
             })

    assert_enqueued(worker: RunSupportAgent, args: %{"conversation_id" => conversation_id})
  end

  test "an imported sync takes Intercom's closed state and asks for no draft", %{workspace: workspace, payload: payload} do
    Req.Test.expect(Intercom, &Req.Test.json(&1, payload))

    assert {:ok, %Conversation{status: :done, drafting_since: nil}} =
             perform_job(SyncIntercomConversation, %{
               "workspace_id" => workspace.id,
               "external_id" => "c1",
               "imported" => true
             })

    refute_enqueued(worker: RunSupportAgent)
  end

  test "a burst of notices for one conversation is read once", %{workspace: workspace} do
    args = %{"workspace_id" => workspace.id, "external_id" => "c1", "draft" => true, "imported" => false}
    {:ok, _first} = args |> SyncIntercomConversation.new(schedule_in: 3) |> Oban.insert()
    {:ok, _second} = args |> SyncIntercomConversation.new(schedule_in: 3) |> Oban.insert()

    assert [%Oban.Job{}] = all_enqueued(worker: SyncIntercomConversation)
  end

  test "a workspace that is gone has nothing to sync" do
    assert :ok = perform_job(SyncIntercomConversation, %{"workspace_id" => "iw_gone", "external_id" => "c1"})
  end
end
