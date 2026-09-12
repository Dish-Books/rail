defmodule Rail.Pipeline.Utils.ProductRunFinished do
  @moduledoc """
  Where a finished product run leaves its task.

  The product agent's ticket stays in scratch until a human approves it: nothing
  is captured here and nothing moves. `approve_product_task/1` is what publishes
  the ticket and enters the next stage.
  """

  alias Rail.Runs.Schemas.Run

  @doc "Finishes `run` as the product stage."
  def product_run_finished(%Run{} = run, _opts), do: run
end
