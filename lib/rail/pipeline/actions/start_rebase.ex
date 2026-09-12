defmodule Rail.Pipeline.Actions.StartRebase do
  @moduledoc """
  Sends the engineer to rebase a conflicted branch.

  A rebase is a detour, not a stage: the task stays parked where it is and the
  engineer's run is borrowed to do the work, which is why `is_rebasing` is the
  whole of it. `rebase_run_finished/2` clears the flag when the branch lands.
  """

  import Rail.Pipeline.Utils.StageRun

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Runs.Schemas.Run

  @doc """
  Starts a rebase pass on `task`.
  """
  def start_rebase(%Task{} = task, opts \\ []) do
    if task |> stage_run() |> Run.running?() do
      {:error, :task_busy}
    else
      execute_rebase_start(task, opts)
    end
  end

  defp execute_rebase_start(%Task{} = task, opts) do
    {:ok, task} =
      task
      |> Task.changeset(%{is_rebasing: true, error: nil})
      |> Repo.update()

    Pipeline.broadcast_pipeline_changed(%{task_id: task.id, event: :rebase_started})

    # The task never leaves its stage, so this re-enters the one it is parked at;
    # `is_rebasing` is what makes the brief a rebase brief.
    Pipeline.enter_stage(task, task.stage, opts)

    {:ok, task}
  end
end
