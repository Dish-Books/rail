defmodule Rail.Support.Actions.HandleIntercomWebhook do
  @moduledoc false

  alias Rail.Support.Schemas.IntercomWorkspace
  alias Rail.Support.Workers.SyncIntercomConversation

  @customer_topics ["conversation.user.created", "conversation.user.replied"]

  @doc """
  Queues a sync of the conversation a verified notice names. Only a customer's message asks for a draft.
  """
  def handle_intercom_webhook(%IntercomWorkspace{id: workspace_id}, %{
        "topic" => "conversation." <> _event = topic,
        "data" => %{"item" => %{"id" => id}}
      })
      when is_binary(id) or is_integer(id) do
    %{
      "workspace_id" => workspace_id,
      "external_id" => to_string(id),
      "draft" => topic in @customer_topics,
      "imported" => false
    }
    |> SyncIntercomConversation.new(schedule_in: 3)
    |> Oban.insert()
  end

  def handle_intercom_webhook(%IntercomWorkspace{}, _payload), do: :ignored
end
