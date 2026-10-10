defmodule Rail.Tools.Workers.SyncSandboxImage do
  @moduledoc """
  Copies Rail's sandbox image to one host, one copy at a time per host. A copy a
  restart cut off is rescued by Oban's Lifeline, and the next connection checks again.
  """
  use Oban.Worker,
    queue: :sandbox_images,
    max_attempts: 1,
    unique: [keys: [:host_id], states: :incomplete, period: :infinity]

  alias Rail.Repo
  alias Rail.Tools
  alias Rail.Tools.Schemas.SandboxHost

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"host_id" => host_id}}) do
    case Repo.get(SandboxHost, host_id) do
      %SandboxHost{removed_at: nil} = host -> _copied_or_failed = Tools.sync_sandbox_image(host)
      _removed_or_gone -> :ok
    end

    :ok
  end
end
