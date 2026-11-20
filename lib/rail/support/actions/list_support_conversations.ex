defmodule Rail.Support.Actions.ListSupportConversations do
  @moduledoc false

  import Ecto.Query

  alias Rail.Repo
  alias Rail.Support.Schemas.Conversation
  alias Rail.Support.Schemas.Message

  @limit 100

  @doc """
  The conversations in one queue filter, `:waiting` unless `:status` says otherwise, newest message first,
  across every project unless `:project_id` names one or a list. Each carries only its first message.
  """
  def list_support_conversations(opts \\ []) when is_list(opts) do
    first_messages =
      from(m in Message, distinct: m.conversation_id, order_by: [asc: m.conversation_id, asc: m.posted_at, asc: m.id])

    Conversation
    |> filter_status(Keyword.get(opts, :status, :waiting))
    |> filter_project(opts[:project_id])
    |> order_by([c], desc_nulls_last: c.last_message_at, desc: c.id)
    |> limit(^Keyword.get(opts, :limit, @limit))
    |> preload([:project, messages: ^first_messages])
    |> Repo.all()
  end

  # Drafting is a Waiting conversation the agent is working on; Waiting is the rest of the open ones.
  defp filter_status(query, :waiting), do: where(query, [c], c.status == :waiting and is_nil(c.drafting_since))
  defp filter_status(query, :drafting), do: where(query, [c], c.status == :waiting and not is_nil(c.drafting_since))
  defp filter_status(query, :done), do: where(query, [c], c.status == :done)

  defp filter_project(query, nil), do: query
  defp filter_project(query, ids) when is_list(ids), do: where(query, [c], c.project_id in ^ids)
  defp filter_project(query, id), do: where(query, [c], c.project_id == ^id)
end
