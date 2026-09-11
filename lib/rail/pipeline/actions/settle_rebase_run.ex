defmodule Rail.Pipeline.Actions.SettleRebaseRun do
  @moduledoc """
  Settles a finished rebase run.

  A rebase is the engineer role doing a detour, so settling it restores the stage
  the task was parked at before the rebase started rather than advancing anything.
  """

  import Rail.Pipeline.Utils.AdvanceStage

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Runs.Schemas.RoleRun
  alias Rail.Runs.Schemas.Run

  @doc "Settles the finished rebase `run` against `outcome`."
  def settle_rebase_run(%Run{} = run, _outcome \\ %{}, opts \\ []) do
    # A rebase changes whether the branch merges, so the answer Rail is holding
    # for that is stale the moment one lands.
    with {:ok, task, %RoleRun{exit_code: 0} = role_run} <- advance_stage(run, opts, &restore_stage_state/3) do
      {:ok, refresh_mergeability(task, opts), role_run}
    end
  end

  defp refresh_mergeability(%Task{} = task, opts) do
    case Pipeline.refresh_mergeability(task, opts) do
      {:ok, refreshed} -> refreshed
      _failure -> task
    end
  end

  defp restore_stage_state(%Task{} = task, role_run, _opts) do
    {:ok, role_run} = role_run |> RoleRun.changeset(%{auto_retries: 0}) |> Repo.update()

    attrs = %{
      is_rebasing: false,
      stage_state: task.stage_state_before_rebase || :queued,
      stage_state_before_rebase: nil,
      retry_after: nil,
      error: nil
    }

    {attrs, role_run}
  end
end
