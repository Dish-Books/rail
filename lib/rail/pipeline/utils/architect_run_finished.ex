defmodule Rail.Pipeline.Utils.ArchitectRunFinished do
  @moduledoc """
  Where a finished architect run leaves its task.

  The architect's ticket edits and its plan file are captured out of scratch here.
  A run that exits cleanly without leaving a plan has not done the job, so the
  failure is recorded on the run rather than parking a human in front of nothing.
  A human approves the plan, and that is what enters the next stage.
  """

  import Ecto.Query
  import Rail.Pipeline.Utils.CaptureScratch

  alias Rail.Pipeline.Schemas.Plan
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Runs.Schemas.Run

  @doc "Finishes `run` as the architect stage."
  def architect_run_finished(%Run{task: %Task{} = task} = run, _opts) do
    {:ok, task} = capture_scratch(:architect, task)

    if Repo.exists?(from p in Plan, where: p.task_id == ^task.id) do
      run
    else
      fail(run, "Architect exited 0 without writing a plan file.")
    end
  end

  defp fail(%Run{} = run, error) do
    {:ok, run} = run |> Run.changeset(%{error: error}) |> Repo.update()
    run
  end
end
