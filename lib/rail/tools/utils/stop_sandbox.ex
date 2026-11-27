defmodule Rail.Tools.Utils.StopSandbox do
  @moduledoc false

  alias Rail.Git
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Tools.Clients.Docker
  alias Rail.Tools.Schemas.Sandbox

  @stop_grace_seconds 10

  @doc """
  Stops `sandbox`'s container and keeps its disk, its task's repo brought up to date with the checkout first so what
  Rail shows of the task stays true while nothing runs. Its token goes with it. Returns the stopped sandbox.
  """
  def stop_sandbox(%Sandbox{container_id: id} = sandbox) do
    _synced = Git.sync_checkout(Repo.get!(Task, sandbox.task_id))

    if is_binary(id) do
      _stopped = Docker.stop_container(id, @stop_grace_seconds)
      _removed = Docker.remove_container(id, force: true)
    end

    stopped =
      sandbox
      |> Sandbox.changeset(%{status: :stopped, container_id: nil, token_hash: nil, stopped_at: DateTime.utc_now()})
      |> Repo.update!()

    Phoenix.PubSub.broadcast(Rail.PubSub, "sandboxes", :sandboxes_changed)
    stopped
  end
end
