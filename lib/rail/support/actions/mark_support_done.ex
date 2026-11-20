defmodule Rail.Support.Actions.MarkSupportDone do
  @moduledoc false

  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Support.Schemas.Conversation

  @doc """
  Mark done: the only way a conversation reaches Done. Marking a done one again changes nothing.
  """
  def mark_support_done(%Scope{user: %{id: user_id}} = scope, %Conversation{id: id}) do
    conversation = Repo.get!(Conversation, id)

    cond do
      not Scope.can_access_project?(scope, conversation.project_id) ->
        {:error, :not_found}

      conversation.status == :done ->
        {:ok, conversation}

      true ->
        conversation = conversation |> Conversation.done_changeset(user_id) |> Repo.update!()
        Phoenix.PubSub.broadcast(Rail.PubSub, "support", {:support_changed, id})
        {:ok, conversation}
    end
  end
end
