defmodule Rail.Pipeline.Actions.GetTask do
  @moduledoc false

  import Ecto.Query

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Gets a single task by ID.
  """
  def get_task(%Scope{system: true}, id) when is_binary(id) do
    do_get_task(id)
  end

  def get_task(%Scope{user: %{}}, id) when is_binary(id) do
    do_get_task(id)
  end

  def get_task(_scope, _id), do: {:error, :not_authorized}

  @doc """
  Gets a single task by ID or raises Ecto.NoResultsError.
  """
  def get_task!(%Scope{system: true}, id) when is_binary(id) do
    do_get_task!(id)
  end

  def get_task!(%Scope{user: %{}}, id) when is_binary(id) do
    do_get_task!(id)
  end

  def get_task!(_scope, _id) do
    raise Ecto.NoResultsError, queryable: Task
  end

  defp do_get_task(id) do
    query = from(t in Task, where: t.id == ^id, preload: [:project, :issue, :plans, :role_runs])

    case Repo.one(query) do
      %Task{} = task -> {:ok, task}
      nil -> {:error, :not_found}
    end
  end

  defp do_get_task!(id) do
    query = from(t in Task, where: t.id == ^id, preload: [:project, :issue, :plans, :role_runs])
    Repo.one!(query)
  end
end
