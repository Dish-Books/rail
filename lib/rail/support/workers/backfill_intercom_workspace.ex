defmodule Rail.Support.Workers.BackfillIntercomWorkspace do
  @moduledoc """
  Imports one page of a workspace's conversations and queues the next page.
  """
  use Oban.Worker,
    queue: :support,
    max_attempts: 10,
    unique: [
      keys: [:workspace_id, :starting_after],
      period: :infinity,
      states: [:available, :scheduled, :executing, :retryable]
    ]

  alias Rail.Support

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"workspace_id" => workspace_id} = args}) do
    case Support.get_intercom_workspace(id: workspace_id) do
      {:ok, workspace} -> Support.backfill_intercom_workspace(workspace, args["starting_after"])
      {:error, :not_found} -> :ok
    end
  end
end
