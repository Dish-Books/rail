defmodule Rail.Support.Actions.GetSupportConversation do
  @moduledoc false

  import Ecto.Query

  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Support.Schemas.ChatMessage
  alias Rail.Support.Schemas.Conversation
  alias Rail.Support.Schemas.Item
  alias Rail.Support.Schemas.Message

  @doc """
  One conversation with everything its page shows. One in a project the scope cannot see is not found.
  """
  def get_support_conversation(scope, id) when is_binary(id) do
    query = from(c in Conversation, where: c.id == ^id)
    query = if ids = Scope.project_ids(scope), do: where(query, [c], c.project_id in ^ids), else: query

    query
    |> preload([
      :project,
      :intercom_workspace,
      :reply_posted_by,
      :done_by,
      messages: ^from(m in Message, order_by: [asc: m.posted_at, asc: m.id]),
      items: ^from(i in Item, order_by: [asc: i.position, asc: i.id], preload: :existing_issue),
      chat_messages: ^from(c in ChatMessage, order_by: [asc: c.inserted_at, asc: c.id], preload: :user)
    ])
    |> Repo.one()
    |> case do
      %Conversation{} = conversation -> {:ok, conversation}
      nil -> {:error, :not_found}
    end
  end
end
