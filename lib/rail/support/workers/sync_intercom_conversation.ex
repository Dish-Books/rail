defmodule Rail.Support.Workers.SyncIntercomConversation do
  @moduledoc """
  Re-reads one Intercom conversation and mirrors it.
  """
  use Oban.Worker,
    queue: :support,
    max_attempts: 5,
    unique: [keys: [:workspace_id, :external_id, :draft, :imported], period: 60, states: [:available, :scheduled]]

  alias Rail.Support

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"workspace_id" => workspace_id, "external_id" => external_id} = args}) do
    case Support.get_intercom_workspace(id: workspace_id) do
      {:ok, workspace} ->
        Support.sync_intercom_conversation(workspace, external_id,
          draft: args["draft"] == true,
          imported: args["imported"] == true
        )

      {:error, :not_found} ->
        :ok
    end
  end
end
