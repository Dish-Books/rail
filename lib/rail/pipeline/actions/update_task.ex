defmodule Rail.Pipeline.Actions.UpdateTask do
  @moduledoc false

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc """
  Updates a task's own attributes. The project binding is immutable here.
  """
  def update_task(%Task{} = task, attrs) do
    task
    |> Task.changeset(attrs)
    |> Repo.update()
  end
end
