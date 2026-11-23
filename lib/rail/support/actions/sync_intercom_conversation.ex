defmodule Rail.Support.Actions.SyncIntercomConversation do
  @moduledoc false

  import Rail.Support.Utils.MirrorIntercomConversation

  alias Rail.Intercom
  alias Rail.Support.Schemas.IntercomWorkspace

  @doc """
  Mirrors the conversation as Intercom has it now, every part upserted by its id, and asks for a
  draft when `draft: true` and a customer wrote since the last one. Returns `{:ok, conversation}`.
  """
  def sync_intercom_conversation(%IntercomWorkspace{} = workspace, external_id, opts \\ []) do
    with {:ok, %{"updated_at" => updated_at} = payload} when is_integer(updated_at) <-
           Intercom.get_conversation(workspace, to_string(external_id)) do
      mirror_intercom_conversation(workspace, Map.put(payload, "id", to_string(external_id)), opts)
    end
  end
end
