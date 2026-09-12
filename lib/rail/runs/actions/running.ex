defmodule Rail.Runs.Actions.Running do
  @moduledoc false

  import Ecto.Query

  alias Rail.Repo
  alias Rail.Runs.Schemas.OsProcess

  @doc """
  Checks if there is an active execution run (:starting or :running) for the given task ID.
  """
  def running?(task_id) when is_binary(task_id) do
    Repo.exists?(
      from r in OsProcess,
        where: r.task_id == ^task_id and r.status in [:starting, :running]
    )
  end

  def running?(_other), do: false
end
