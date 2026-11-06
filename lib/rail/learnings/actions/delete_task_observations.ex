defmodule Rail.Learnings.Actions.DeleteTaskObservations do
  @moduledoc """
  Forgets the sightings Rail recorded from a discarded task's corrections. A rule already learned from them stays.
  """

  import Ecto.Query

  alias Rail.Learnings.Schemas.Observation
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc """
  Deletes every observation recorded from `task`.
  """
  def delete_task_observations(%Task{id: task_id}) do
    {_deleted, nil} = Repo.delete_all(from(o in Observation, where: o.task_id == ^task_id))
    :ok
  end
end
