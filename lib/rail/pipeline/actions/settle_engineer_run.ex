defmodule Rail.Pipeline.Actions.SettleEngineerRun do
  @moduledoc """
  Settles a finished engineer-stage run.

  The engineer produces no artifact Rail reads; a clean exit simply queues the
  review gate on what was pushed.
  """

  import Rail.Pipeline.Utils.AdvanceStage

  alias Rail.Repo
  alias Rail.Runs.Schemas.OsProcess
  alias Rail.Runs.Schemas.Run

  @doc "Settles the finished engineer `run` against `outcome`."
  def settle_engineer_run(%OsProcess{} = os_process, _outcome \\ %{}, opts \\ []) do
    advance_stage(os_process, opts, &queue_review/3)
  end

  defp queue_review(_task, run, _opts) do
    {:ok, run} = run |> Run.changeset(%{auto_retries: 0}) |> Repo.update()

    {%{stage: :review, stage_state: :queued, retry_after: nil, error: nil}, run}
  end
end
