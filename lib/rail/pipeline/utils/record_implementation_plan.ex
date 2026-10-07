defmodule Rail.Pipeline.Utils.RecordImplementationPlan do
  @moduledoc false

  alias Rail.Pipeline.Schemas.ImplementationPlan
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc """
  Records `content` as the plan `task`'s engineer builds from. There is one per task, so approving again after a
  return to Plan, or a revision saved after approval, replaces it.
  """
  def record_implementation_plan(%Task{} = task, content) do
    existing = Repo.get_by(ImplementationPlan, task_id: task.id) || %ImplementationPlan{}

    existing
    |> ImplementationPlan.changeset(%{task_id: task.id, content: content, captured_at: DateTime.utc_now()})
    |> Repo.insert_or_update!()
  end
end
