defmodule Rail.Support.Actions.UpdateSupportDraft do
  @moduledoc false

  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Support.Schemas.Conversation

  @doc """
  Saves the reply as the person types it, refused while a pass works on it or once it is posted.
  """
  def update_support_draft(%Scope{} = scope, %Conversation{id: id}, attrs) do
    conversation = Repo.get!(Conversation, id)

    cond do
      not Scope.can_access_project?(scope, conversation.project_id) ->
        {:error, :not_found}

      Conversation.drafting?(conversation) ->
        {:error, :drafting}

      is_struct(conversation.reply_posted_at, DateTime) ->
        {:error, :already_sent}

      true ->
        with {:ok, conversation} <- conversation |> Conversation.draft_changeset(attrs) |> Repo.update() do
          Phoenix.PubSub.broadcast(Rail.PubSub, "support", {:support_changed, id})
          {:ok, conversation}
        end
    end
  end
end
