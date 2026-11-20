defmodule Rail.Support.Actions.BackfillIntercomWorkspace do
  @moduledoc false

  alias Rail.Intercom
  alias Rail.Support.Schemas.IntercomWorkspace
  alias Rail.Support.Workers.BackfillIntercomWorkspace
  alias Rail.Support.Workers.SyncIntercomConversation

  @doc """
  Reads one page of conversations and queues a sync of each, then the next page.
  """
  def backfill_intercom_workspace(%IntercomWorkspace{id: workspace_id} = workspace, starting_after) do
    with {:ok, conversations, next} <- Intercom.list_conversations(workspace, starting_after) do
      _syncs =
        conversations
        |> Enum.map(
          &SyncIntercomConversation.new(%{
            "workspace_id" => workspace_id,
            "external_id" => to_string(&1["id"]),
            "draft" => false,
            "imported" => true
          })
        )
        |> Oban.insert_all()

      # Oban's batch insert skips the uniqueness check, so the next page goes in on its own.
      if next,
        do:
          {:ok, _page} =
            Oban.insert(BackfillIntercomWorkspace.new(%{"workspace_id" => workspace_id, "starting_after" => next}))

      :ok
    end
  end
end
