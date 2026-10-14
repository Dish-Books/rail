defmodule Rail.Pipeline.Actions.StartPlan do
  @moduledoc """
  The task's owner starts the work of its plan without waiting for a tech lead, as `start_planned_work/4`
  describes. The plan reads as sent, so it sits in the leads' queue until one approves it, and the task cannot
  merge before then.
  """

  import Rail.Pipeline.Utils.StartPlannedWork

  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Scope

  @doc """
  Starts the work of the plan the Plan `run` saved as the scope's user. Returns `{:ok, run}`, or `{:error, reason}`:
  `:not_owner` for anyone but the task's owner, or what the plan is missing.
  """
  def start_plan(%Scope{} = scope, %Run{} = run) do
    start_planned_work(scope, run, :ready, fn task, _round ->
      if scope.system or Task.owned_by?(task, scope), do: :ok, else: {:error, :not_owner}
    end)
  end
end
