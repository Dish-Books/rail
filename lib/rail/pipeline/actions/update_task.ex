defmodule Rail.Pipeline.Actions.UpdateTask do
  @moduledoc false

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc """
  Updates a task's own attributes. The project binding is immutable here.
  """
  def update_task(_scope, %Task{} = task, attrs) do
    task
    |> Task.changeset(attrs)
    |> Repo.update()
  end

  def update_task(scope, id, attrs) when is_binary(id) do
    case Repo.get(Task, id) do
      %Task{} = task -> update_task(scope, task, attrs)
      nil -> {:error, :not_found}
    end
  end
end
