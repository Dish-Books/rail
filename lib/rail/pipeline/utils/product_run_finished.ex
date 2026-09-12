defmodule Rail.Pipeline.Utils.ProductRunFinished do
  @moduledoc """
  Where a clean product run leaves its task.

  The product agent's ticket stays in scratch until a human approves it: nothing is
  captured here, a clean exit only parks the task at `awaiting_approval`, and
  `approve_product_task/2` is what publishes the ticket and moves the pipeline on.
  """

  alias Rail.Repo
  alias Rail.Runs.Schemas.Run

  @doc """
  Returns the `{task_attrs, run}` that park `task` for approval.
  """
  def product_run_finished(_task, %Run{} = run, _opts) do
    {:ok, run} = run |> Run.changeset(%{auto_retries: 0}) |> Repo.update()

    {%{stage_state: :awaiting_approval, retry_after: nil, error: nil}, run}
  end
end
