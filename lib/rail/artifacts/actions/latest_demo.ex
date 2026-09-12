defmodule Rail.Artifacts.Actions.LatestDemo do
  @moduledoc false

  import Ecto.Query

  alias Rail.Artifacts.Schemas.Demo
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc """
  The most recent demo recorded for `task`, or `nil`.
  """
  def latest_demo(%Task{id: task_id}) do
    Repo.one(from d in Demo, where: d.task_id == ^task_id, order_by: [desc: d.version], limit: 1)
  end
end
