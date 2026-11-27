defmodule Rail.Tools.Actions.EndTaskSandbox do
  @moduledoc false

  import Ecto.Query

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Tools.Clients.Docker
  alias Rail.Tools.Schemas.Sandbox

  @doc """
  Ends `task`'s sandbox once its checkout is no longer wanted: its container, if it has one, and its disk. Nothing is
  synced first, since nothing of the checkout is kept. Returns `:ok`, also for a task that never had one.
  """
  def end_task_sandbox(%Task{id: task_id}) do
    for %Sandbox{} = sandbox <- Repo.all(from s in Sandbox, where: s.task_id == ^task_id and s.status != :ended) do
      if is_binary(sandbox.container_id), do: Docker.remove_container(sandbox.container_id, force: true)
      _removed = Docker.remove_volume(sandbox.volume)

      sandbox
      |> Sandbox.changeset(%{status: :ended, container_id: nil, token_hash: nil, ended_at: DateTime.utc_now()})
      |> Repo.update!()
    end

    Phoenix.PubSub.broadcast(Rail.PubSub, "sandboxes", :sandboxes_changed)
    :ok
  end
end
