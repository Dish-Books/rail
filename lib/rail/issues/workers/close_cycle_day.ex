defmodule Rail.Issues.Workers.CloseCycleDay do
  @moduledoc """
  The 00:05 UTC cron: records the day just ended for every Rail-tracked cycle, schedules cycles ahead and rolls over
  the issues of each cycle that ended. A second run the same day changes nothing, so it needs no uniqueness.
  """
  use Oban.Worker, queue: :issues

  alias Rail.Issues

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: Issues.close_cycle_day(Date.utc_today())
end
