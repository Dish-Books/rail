defmodule Rail.Support.Actions.SendSupportChat do
  @moduledoc false

  import Rail.Support.Utils.RequestSupportDraft

  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Support.Schemas.ChatMessage
  alias Rail.Support.Schemas.Conversation

  @doc """
  Records the person's chat message and asks for a pass to act on it.
  """
  def send_support_chat(%Scope{user: user} = scope, %Conversation{} = conversation, attrs) do
    with true <- Scope.can_access_project?(scope, conversation.project_id) || {:error, :not_found},
         {:ok, message} <- conversation |> ChatMessage.person_changeset(user, attrs) |> Repo.insert(),
         {:ok, _conversation} <- request_support_draft(conversation) do
      {:ok, message}
    end
  end
end
