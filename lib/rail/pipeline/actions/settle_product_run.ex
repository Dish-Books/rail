defmodule Rail.Pipeline.Actions.SettleProductRun do
  @moduledoc """
  Settles a finished product-stage run.

  The product agent's ticket stays in scratch until a human approves it: nothing is
  captured here, a clean exit only parks the task at `awaiting_approval`, and
  `approve_product_task/2` is what publishes the ticket and moves the pipeline on.
  """

  import Rail.Pipeline.Utils.AdvanceStage
  import Rail.Pipeline.Utils.ProductRunFinished

  alias Rail.Runs.Schemas.OsProcess

  @doc "Settles the finished product `run` against `outcome`."
  def settle_product_run(%OsProcess{} = os_process, _outcome \\ %{}, opts \\ []) do
    advance_stage(os_process, opts, &product_run_finished/3)
  end
end
