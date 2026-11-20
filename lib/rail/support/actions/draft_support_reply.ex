defmodule Rail.Support.Actions.DraftSupportReply do
  @moduledoc false

  import Rail.Support.Utils.RequestSupportDraft

  alias Rail.Scope
  alias Rail.Support.Schemas.Conversation

  @doc """
  Draft a reply, on a conversation no agent has read, and Try again after a failed pass.
  """
  def draft_support_reply(%Scope{} = scope, %Conversation{} = conversation) do
    if Scope.can_access_project?(scope, conversation.project_id),
      do: request_support_draft(conversation),
      else: {:error, :not_found}
  end
end
