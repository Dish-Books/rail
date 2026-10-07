defmodule Rail.Pipeline.Utils.RecordImplementationPlan do
  @moduledoc false

  alias Rail.Pipeline.Schemas.ImplementationPlan
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc """
  Records `content` as the plan `task`'s engineer builds from. There is one per task, so approving again after a
  return to Plan, or a revision saved after approval, replaces it. An approval starts afresh and is `captured_at`; a
  revision keeps that and is stamped with its own time.
  """
  def record_implementation_plan(%Task{} = task, content, revision?) do
    existing = Repo.get_by(ImplementationPlan, task_id: task.id) || %ImplementationPlan{}
    now = DateTime.utc_now()

    attrs =
      if revision?,
        do: %{task_id: task.id, content: content, plan_revised_at: now},
        else: %{
          task_id: task.id,
          content: content,
          captured_at: now,
          plan_revised_at: nil,
          ticket_revised_at: nil,
          announced_at: nil
        }

    existing
    |> ImplementationPlan.changeset(attrs)
    |> Repo.insert_or_update!()
  end
end
