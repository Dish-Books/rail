defmodule Rail.Pipeline.Utils.QaLeadRunFinished do
  @moduledoc """
  Where a finished QA lead run leaves its task.

  QA lead is the last gate: a pass goes to the demo stage when the project has a
  demo role, and straight to the merge when it does not.
  """

  import Rail.Pipeline.Utils.GateOutcome

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Roles
  alias Rail.Runs.Schemas.Run

  @doc "Finishes `run` as the QA lead stage."
  def qa_lead_run_finished(%Run{task: %Task{} = task} = run, opts) do
    next_stage =
      case Roles.get_role(project_id: task.project_id, stage: :demo) do
        {:ok, _role} -> :demo
        _no_demo -> :ready_to_merge
      end

    gate_outcome(run, next_stage, opts)
  end
end
