defmodule Rail.Pipeline.Actions.SettleQaLeadRun do
  @moduledoc """
  Settles a finished QA lead-stage run.

  QA lead is the last gate: a pass goes to the demo stage when the project has a
  demo role, and straight to the merge when it does not.
  """

  import Rail.Pipeline.Utils.AdvanceStage
  import Rail.Pipeline.Utils.GateOutcome

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Roles
  alias Rail.Runs.Schemas.OsProcess

  @doc "Settles the finished QA lead `run` against `outcome`."
  def settle_qa_lead_run(%OsProcess{} = os_process, _outcome \\ %{}, opts \\ []) do
    advance_stage(os_process, opts, &to_demo_or_merge/3)
  end

  defp to_demo_or_merge(%Task{} = task, run, _opts) do
    next_stage =
      case Roles.get_role(project_id: task.project_id, stage: :demo) do
        {:ok, _role} -> :demo
        _no_demo -> :ready_to_merge
      end

    gate_outcome(task, run, next_stage)
  end
end
