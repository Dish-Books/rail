defmodule Rail.Pipeline.Actions.GetPlan do
  @moduledoc false

  import Ecto.Query

  alias Rail.Pipeline.Schemas.Plan
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc """
  Gets the latest implementation plan for `task`.
  """
  def get_plan(%Task{id: task_id}) do
    query =
      from(p in Plan,
        where: p.task_id == ^task_id,
        order_by: [desc: p.captured_at, desc: p.inserted_at],
        limit: 1
      )

    case Repo.one(query) do
      %Plan{} = plan -> {:ok, plan}
      nil -> {:error, :not_found}
    end
  end
end
