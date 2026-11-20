defmodule Rail.Support.Actions.CountSupportConversations do
  @moduledoc false

  import Ecto.Query

  alias Rail.Repo
  alias Rail.Support.Schemas.Conversation

  @doc """
  How many conversations are in each queue filter, across every project unless `:project_id` names one or a list.
  """
  def count_support_conversations(opts) when is_list(opts) do
    query =
      if ids = opts[:project_id], do: where(Conversation, [c], c.project_id in ^List.wrap(ids)), else: Conversation

    query
    |> select([c], %{
      waiting: filter(count(c.id), c.status == :waiting and is_nil(c.drafting_since)),
      drafting: filter(count(c.id), c.status == :waiting and not is_nil(c.drafting_since)),
      done: filter(count(c.id), c.status == :done)
    })
    |> Repo.one()
  end
end
