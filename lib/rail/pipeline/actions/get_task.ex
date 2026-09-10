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
    query = from(t in Task, where: t.id == ^id, preload: [:project, :issue, :plans, :role_runs, :designs, :demos])

    case Repo.one(query) do
      %Task{} = task -> {:ok, attach_latest_artifacts(task)}
      nil -> {:error, :not_found}
    end
  end

  defp do_get_task!(id) do
    query = from(t in Task, where: t.id == ^id, preload: [:project, :issue, :plans, :role_runs, :designs, :demos])
    query |> Repo.one!() |> attach_latest_artifacts()
  end

  defp attach_latest_artifacts(%Task{} = task) do
    latest_demo =
      if is_list(task.demos) and task.demos != [] do
        Enum.max_by(task.demos, & &1.version)
      end

    latest_design =
      if is_list(task.designs) and task.designs != [] do
        Enum.max_by(task.designs, & &1.version)
      end

    %{task | demo: latest_demo, design: latest_design}
  end
end
