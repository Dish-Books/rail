defmodule Rail.Pipeline.Actions.SettleProductRun do
  @moduledoc """
  Settles a finished product-stage run.

  The product agent's ticket stays in scratch until a human approves it: nothing is
  captured here, a clean exit only parks the task at `awaiting_approval`, and
  `approve_product_task/2` is what publishes the ticket and moves the pipeline on.
  """

  import Rail.Pipeline.Utils.AdvanceStage

  alias Rail.Repo
  alias Rail.Runs.Schemas.OsProcess
  alias Rail.Runs.Schemas.Run

  @doc "Settles the finished product `run` against `outcome`."
  def settle_product_run(%OsProcess{} = os_process, _outcome \\ %{}, opts \\ []) do
    advance_stage(os_process, opts, &awaiting_approval/3)
  end

  defp awaiting_approval(_task, run, _opts) do
    {:ok, run} = run |> Run.changeset(%{auto_retries: 0}) |> Repo.update()

    {%{stage_state: :awaiting_approval, retry_after: nil, error: nil}, run}
  end
end
