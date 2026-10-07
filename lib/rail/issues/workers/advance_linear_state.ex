defmodule Rail.Issues.Workers.AdvanceLinearState do
  @moduledoc """
  The name `Rail.Issues.Workers.AdvanceTrackerState` had while Linear was the only tracker,
  kept so a job queued under it before a deploy still runs.
  """
  use Oban.Worker, queue: :issues, max_attempts: 5

  alias Rail.Issues.Workers.AdvanceTrackerState

  @impl Oban.Worker
  def perform(%Oban.Job{} = job), do: AdvanceTrackerState.perform(job)
end
