defmodule Rail.Tools.Workers.RefreshUsage do
  @moduledoc """
  Probes every configured backend every five minutes, so quota and account state
  on the backends page are current without someone opening it and hitting refresh.

  A probe shells out to the CLI, so five minutes keeps the cost low while staying
  well inside the window a session limit resets in.
  """
  use Oban.Worker, queue: :tools, max_attempts: 1, unique: [period: 295]

  alias Rail.Tools

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    _refreshed = Tools.refresh_usage()
    :ok
  end
end
