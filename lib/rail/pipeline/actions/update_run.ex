defmodule Rail.Pipeline.Actions.UpdateRun do
  @moduledoc false

  import Ecto.Changeset, only: [changed?: 2]
  import Rail.Pipeline.Utils.BroadcastPipelineChanged

  alias Rail.Pipeline.Schemas.Run
  alias Rail.Repo

  @doc """
  Updates a run record, and says so on `"pipeline"` when its status or error changed.
  """
  def update_run(%Run{} = run, attrs) do
    changeset = Run.changeset(run, attrs)

    with {:ok, updated} <- Repo.update(changeset) do
      if changed?(changeset, :status) or changed?(changeset, :error), do: broadcast_pipeline_changed(updated)
      {:ok, updated}
    end
  end
end
