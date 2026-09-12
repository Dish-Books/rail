defmodule Rail.Pipeline.Actions.GetTask do
  @moduledoc false

  import Ecto.Query

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc """
  Gets a single task by ID, with its project, issue and runs loaded.

  Artifacts are not loaded here. What a page shows is the page's business: the
  one that draws a design panel asks for the design.
  """
  def get_task(id) when is_binary(id) do
    query = from(t in Task, where: t.id == ^id, preload: [:project, :issue, runs: :role])

    case Repo.one(query) do
      %Task{} = task -> {:ok, task}
      nil -> {:error, :not_found}
    end
  end
end
