defmodule Rail.Artifacts.Actions.LatestDesign do
  @moduledoc false

  import Ecto.Query

  alias Rail.Artifacts.Schemas.Design
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc """
  The most recent design captured for `task`, or `nil`.
  """
  def latest_design(%Task{id: task_id}) do
    Repo.one(from d in Design, where: d.task_id == ^task_id, order_by: [desc: d.version], limit: 1)
  end
end
