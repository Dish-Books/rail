defmodule Rail.Pipeline.Actions.GetPlan do
  @moduledoc false

  import Ecto.Query

  alias Rail.Pipeline.Schemas.Plan
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Gets the latest implementation plan for a task by task or task ID with scope authorization.
  """
  def get_plan(%Scope{system: true}, task_or_id) do
    do_get_plan(task_or_id)
  end

  def get_plan(%Scope{user: %{}}, task_or_id) do
    do_get_plan(task_or_id)
  end

  def get_plan(_scope, _task_or_id), do: {:error, :not_authorized}

  @doc """
  Gets the latest implementation plan for a task by task or task ID without explicit scope.
  """
  def get_plan(task_or_id) do
    do_get_plan(task_or_id)
  end

  defp do_get_plan(%Task{id: task_id}) when is_binary(task_id) do
    do_get_plan(task_id)
  end

  defp do_get_plan(task_id) when is_binary(task_id) do
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

  defp do_get_plan(_other), do: {:error, :not_found}
end
