defmodule Rail.Support.Actions.HandleIntercomWebhookTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Support
  alias Rail.Support.Schemas.IntercomWorkspace
  alias Rail.Support.Workers.SyncIntercomConversation

  setup do
    %{workspace: %IntercomWorkspace{id: "iw_webhook"}}
  end

  test "a customer's new conversation or reply queues a sync that asks for a draft", %{workspace: workspace} do
    for topic <- ["conversation.user.created", "conversation.user.replied"] do
      assert {:ok, %Oban.Job{}} =
               Support.handle_intercom_webhook(workspace, %{"topic" => topic, "data" => %{"item" => %{"id" => 77}}})
    end

    assert [
             %Oban.Job{
               args: %{"workspace_id" => "iw_webhook", "external_id" => "77", "draft" => true, "imported" => false}
             }
           ] = all_enqueued(worker: SyncIntercomConversation)
  end

  test "a note, a teammate's reply, Fin's or a close queues a sync that asks for none", %{workspace: workspace} do
    for topic <- [
          "conversation.admin.noted",
          "conversation.admin.replied",
          "conversation.operator.replied",
          "conversation.admin.closed"
        ] do
      assert {:ok, %Oban.Job{}} =
               Support.handle_intercom_webhook(workspace, %{"topic" => topic, "data" => %{"item" => %{"id" => "88"}}})
    end

    assert [%Oban.Job{args: %{"external_id" => "88", "draft" => false}, scheduled_at: %DateTime{}}] =
             all_enqueued(worker: SyncIntercomConversation)
  end

  test "Intercom's ping, other topics and a notice with no conversation are ignored", %{workspace: workspace} do
    assert :ignored = Support.handle_intercom_webhook(workspace, %{"topic" => "ping", "data" => %{"item" => %{}}})

    assert :ignored =
             Support.handle_intercom_webhook(workspace, %{
               "topic" => "contact.created",
               "data" => %{"item" => %{"id" => "1"}}
             })

    assert :ignored =
             Support.handle_intercom_webhook(workspace, %{
               "topic" => "conversation.user.created",
               "data" => %{"item" => %{"id" => nil}}
             })

    assert :ignored = Support.handle_intercom_webhook(workspace, %{})

    refute_enqueued(worker: SyncIntercomConversation)
  end
end
