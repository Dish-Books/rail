defmodule Rail.Pipeline.Actions.ListTasks do
  @moduledoc false

  import Ecto.Query

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc """
  Lists tasks for a project with optional filters.
  """
  def list_tasks(opts \\ []) do
    order_by = opts[:order_by] || [asc: :inserted_at]
    preload = opts[:preload] || []

    query =
      from t in Task,
        preload: ^preload,
        order_by: ^oder_by

    query =
      if is_binary(opts[:project_id]) do
        where(query, [t], t.project_id == ^project_id)
      else
        query
      end

    query =
      case opts[:stage] do
        stage when is_atom(stage) and stage != nil -> where(query, [t], t.stage == ^stage)
        nil -> query
      end

    Repo.all(query)
  end
end
