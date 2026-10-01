defmodule Rail.Pipeline.Actions.CountAttention do
  @moduledoc false

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run

  @doc """
  Counts the tasks waiting on a human, across every project, the same way the
  Overview lists them: a task waits only if the latest run at its stage does.
  """
  def count_attention do
    [preload: [:role, :questions, task: :issue]]
    |> Pipeline.list_runs()
    |> Enum.filter(&(&1.role.stage == &1.task.stage))
    |> Enum.group_by(& &1.task_id)
    |> Enum.count(fn {_task_id, stage_runs} ->
      stage_runs |> Enum.max_by(&(&1.started_at || &1.inserted_at), DateTime) |> Run.needs_attention?()
    end)
  end
end
