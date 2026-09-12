defmodule Rail.Pipeline.Actions.ListTasks do
  @moduledoc false

  import Ecto.Query

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc """
  Lists tasks for a project with optional filters.
  """
  def list_tasks(project_id, opts \\ []) when is_binary(project_id) or is_nil(project_id) do
    fetch_tasks(project_id, opts)
  end

  defp fetch_tasks(project_id, opts) do
    query = from(t in Task)

    query =
      if is_binary(project_id) do
        from(t in query, where: t.project_id == ^project_id)
      else
        query
      end

    query =
      case Keyword.get(opts, :stage) do
        stage when is_atom(stage) and stage != nil -> from(t in query, where: t.stage == ^stage)
        nil -> query
      end

    query =
      case Keyword.get(opts, :stage_state) do
        state when is_atom(state) and state != nil -> from(t in query, where: t.stage_state == ^state)
        nil -> query
      end

    query =
      case Keyword.get(opts, :preload) do
        preloads when is_list(preloads) and preloads != [] -> from(t in query, preload: ^preloads)
        _other -> query
      end

    order = Keyword.get(opts, :order_by, asc: :inserted_at)
    query = from(t in query, order_by: ^order)

    Repo.all(query)
  end
end
