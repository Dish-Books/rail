defmodule Rail.Pipeline.Actions.ApprovePlan do
  @moduledoc """
  Records the implementation plan the architect wrote, and hands the task to the
  engineer.

  The architect writes its plan into scratch and nothing else, because a human has
  to read it first. Approving is what makes the plan the one the engineer builds
  from, so it is copied out of scratch into a row of its own: the architect can go
  on editing that file afterwards without quietly changing what was agreed.

  Approving is a one-way door: the task leaves architect, and a task no longer
  there has nothing left to approve. One plan per task, so a second architect pass
  replaces what the first one said.
  """

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.ImplementationPlan
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc """
  Approves the plan `run` wrote and enters the engineer stage.

  Returns `{:ok, run}`, the run that was handed in, latched done.
  """
  def approve_plan(%Run{} = run) do
    run = Repo.preload(run, [task: [:issue, :runs]], force: true)

    with :ok <- approvable(run.task),
         {:ok, content} <- plan(run.task) do
      record(run.task, content)
      enter_next(run)
    end
  end

  defp approvable(%Task{stage: stage}) when stage != :architect, do: {:error, {:invalid_stage, stage}}

  defp approvable(%Task{} = task) do
    if Task.running?(task), do: {:error, :stage_running}, else: :ok
  end

  defp plan(%Task{} = task) do
    case Pipeline.read_plan(task) do
      content when is_binary(content) -> {:ok, content}
      nil -> {:error, :no_plan}
    end
  end

  defp record(%Task{} = task, content) do
    existing = Repo.get_by(ImplementationPlan, task_id: task.id) || %ImplementationPlan{}

    existing
    |> ImplementationPlan.changeset(%{task_id: task.id, content: content, captured_at: DateTime.utc_now()})
    |> Repo.insert_or_update!()
  end

  # The run has said all it is going to: latch it before the next stage starts, so
  # nothing that happens there can send this one round again.
  defp enter_next(%Run{} = run) do
    {:ok, run} = run |> Run.changeset(%{stage_outcome: :done}) |> Repo.update()
    {:ok, _next} = Pipeline.enter_stage(run.task, :engineer)

    {:ok, run}
  end
end
