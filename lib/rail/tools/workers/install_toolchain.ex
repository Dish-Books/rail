defmodule Rail.Tools.Workers.InstallToolchain do
  @moduledoc """
  Runs one toolchain install, on a queue of one so two never share mise's build
  directory. A job orphaned by a restart is left where it is: boot queues another.
  """
  use Oban.Worker,
    queue: :toolchains,
    max_attempts: 1,
    unique: [keys: [:install_id], states: [:available, :scheduled, :retryable], period: :infinity]

  alias Rail.Tools

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"install_id" => install_id}}) do
    _installed_failed_or_settled = Tools.install_toolchain(install_id)
    :ok
  end
end
