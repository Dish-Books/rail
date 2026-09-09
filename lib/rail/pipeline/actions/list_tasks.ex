defmodule Rail.Pipeline.Actions.ListTasks do
  @moduledoc false

  import Ecto.Query

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Lists tasks for a project with optional filters.
  """
  def list_tasks(scope, project_id, opts \\ [])

  def list_tasks(%Scope{system: true}, project_id, opts) when is_binary(project_id) do
    fetch_tasks(project_id, opts)
  end

  def list_tasks(%Scope{user: %{}}, project_id, opts) when is_binary(project_id) do
    fetch_tasks(project_id, opts)
  end

  def list_tasks(_scope, _project_id, _opts), do: []

  defp fetch_tasks(project_id, opts) do
    query = from(t in Task, where: t.project_id == ^project_id)

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

    order = Keyword.get(opts, :order_by, asc: :inserted_at)
    query = from(t in query, order_by: ^order)

    Repo.all(query)
  end
end
