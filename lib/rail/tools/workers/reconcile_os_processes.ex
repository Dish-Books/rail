defmodule Rail.Tools.Workers.ReconcileOsProcesses do
  @moduledoc """
  Runs `Rail.Tools.Boot`'s reconcile every minute, so a process that lost its
  Follower after boot is picked up again without waiting for a restart.

  A Follower restarts on its own when it crashes; this is for everything that does
  not survive: a supervisor that gave up on a crash loop, or a Follower killed out
  from under it. Without it the run's log stops and the run reads as running
  forever.
  """
  use Oban.Worker, queue: :tools, max_attempts: 1, unique: [period: 55]

  alias Rail.Tools.Boot

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    _reconciled = Boot.reconcile()
    :ok
  end
end
