defmodule Rail.Pipeline.Actions.SettleArchitectRun do
  @moduledoc """
  Settles a finished architect-stage run.

  The architect's ticket edits and its plan file are captured out of scratch here.
  A run that exits cleanly without leaving a plan has not done the job, so the
  stage fails rather than parking a human in front of nothing.
  """

  import Ecto.Query
  import Rail.Pipeline.Utils.AdvanceStage
  import Rail.Pipeline.Utils.CaptureScratch

  alias Rail.Pipeline.Schemas.Plan
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Runs.Schemas.RoleRun
  alias Rail.Runs.Schemas.Run

  @doc "Settles the finished architect `run` against `outcome`."
  def settle_architect_run(%Run{} = run, _outcome \\ %{}, opts \\ []) do
    advance_stage(run, opts, &capture_plan/3)
  end

  defp capture_plan(%Task{} = task, role_run, _opts) do
    {:ok, task} = capture_scratch(:architect, task)

    if Repo.exists?(from p in Plan, where: p.task_id == ^task.id) do
      {:ok, role_run} = role_run |> RoleRun.changeset(%{auto_retries: 0}) |> Repo.update()

      {%{stage_state: :awaiting_approval, retry_after: nil, error: nil}, role_run}
    else
      attrs = %{
        stage_state: :failed,
        error: "Architect exited 0 without writing a plan file.",
        retry_after: nil
      }

      {attrs, role_run}
    end
  end
end
