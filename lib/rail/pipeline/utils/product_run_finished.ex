defmodule Rail.Pipeline.Utils.ProductRunFinished do
  @moduledoc """
  Where a finished product-stage run leaves its task.

  The product agent's ticket stays in scratch until a human approves it: nothing is
  captured here, a clean exit only parks the task at `awaiting_approval`, and
  `approve_product_task/1` is what publishes the ticket and moves the pipeline on.
  """

  import Rail.Pipeline.Utils.AdvanceStage

  alias Rail.Repo
  alias Rail.Runs.Schemas.OsProcess
  alias Rail.Runs.Schemas.Run

  @doc "Finishes the product run that `os_process` belonged to."
  def finish_product_run(%OsProcess{} = os_process, _outcome \\ %{}, opts \\ []) do
    advance_stage(os_process, opts, &park_for_approval/3)
  end

  defp park_for_approval(_task, %Run{} = run, _opts) do
    {:ok, run} = run |> Run.changeset(%{auto_retries: 0}) |> Repo.update()

    {%{stage_state: :awaiting_approval, retry_after: nil, error: nil}, run}
  end
end
