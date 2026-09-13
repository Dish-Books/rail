defmodule Rail.Pipeline.Actions.RerecordDemo do
  @moduledoc """
  Records a task's demo again.

  The previous recording is marked stale rather than deleted — it is still what a
  human saw — and the demo stage is entered afresh. A merged task or a worktree
  that is no longer on disk has nothing to record from.
  """

  alias Rail.Artifacts
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Runs.Schemas.Run
  alias Rail.Scope

  @doc """
  Returns true if `run`'s task is eligible to re-record its demo.
  """
  def can_rerecord_demo?(%Run{task: %Task{stage: stage} = task}) when stage in [:ready_to_merge, :demo] do
    is_nil(task.merged_at) and not Task.running?(task) and Task.worktree_present?(task)
  end

  def can_rerecord_demo?(_other), do: false

  @doc """
  Re-records the demo for `run`'s task.
  """
  def rerecord_demo(%Run{} = run, opts \\ []) do
    %Run{task: %Task{} = task} = run = Repo.preload(run, task: :runs)

    cond do
      task.stage == :merged or task.merged_at != nil ->
        {:error, :task_merged}

      not Task.worktree_present?(task) ->
        {:ok, _failed} =
          run
          |> Run.changeset(%{error: "Worktree does not exist on disk (#{task.worktree_path})."})
          |> Repo.update()

        {:error, :no_worktree}

      true ->
        _mark_result = Artifacts.mark_demo_stale(Scope.for_system(), task.id)
        Pipeline.enter_stage(task, :demo, opts)
    end
  end
end
