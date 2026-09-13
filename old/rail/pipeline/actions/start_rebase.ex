defmodule Rail.Pipeline.Actions.StartRebase do
  @moduledoc """
  Sends the engineer to rebase a conflicted branch.

  A rebase is a detour, not a stage: the task stays parked where it is and the
  engineer's run is borrowed to do the work, which is why `is_rebasing` is the
  whole of it. `rebase_run_finished/2` clears the flag when the branch lands.
  """

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc """
  Starts a rebase pass on `task`.
  """
  def start_rebase(%Task{} = task, opts \\ []) do
    task = Repo.preload(task, :runs)

    if Task.running?(task) do
      {:error, :task_busy}
    else
      execute_rebase_start(task, opts)
    end
  end

  defp execute_rebase_start(%Task{} = task, opts) do
    {:ok, task} =
      task
      |> Task.changeset(%{is_rebasing: true})
      |> Repo.update()

    # The task never leaves its stage, so this re-enters the one it is parked at;
    # `is_rebasing` is what makes the brief a rebase brief.
    Pipeline.enter_stage(task, task.stage, opts)

    {:ok, task}
  end
end
